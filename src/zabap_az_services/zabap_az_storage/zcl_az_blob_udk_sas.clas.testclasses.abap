*"* use this source file for your ABAP unit test classes

CLASS ltc_udk_getkey DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    DATA mo_http TYPE REF TO zcl_az_http_client_mock.
    DATA mo_cred TYPE REF TO zcl_az_token_credential_fake.
    DATA mo_cut  TYPE REF TO zcl_az_blob_udk_sas.

    METHODS setup.

    "! A well-formed <UserDelegationKey> is parsed into all signed-key fields.
    METHODS parses_delegation_key    FOR TESTING RAISING zcx_azure.
    "! POSTs /?restype=service&comp=userdelegationkey with the KeyInfo body + version.
    METHODS builds_getkey_request    FOR TESTING RAISING zcx_azure.
    "! Auth policy asks the credential for the storage data-plane scope.
    METHODS uses_storage_scope       FOR TESTING RAISING zcx_azure.
    "! A non-2xx surfaces as a typed zcx_azure.
    METHODS http_error_raises        FOR TESTING.
    "! Phase 3: the returned client authenticates its requests with the UDK SAS
    "! (skoid + sig land in the request URL via zcl_az_policy_sas).
    METHODS create_client_appends_sas FOR TESTING RAISING zcx_azure.

    METHODS sample_key_xml RETURNING VALUE(rv) TYPE string.
ENDCLASS.


CLASS ltc_udk_getkey IMPLEMENTATION.

  METHOD setup.
    mo_http = NEW zcl_az_http_client_mock( ).
    mo_cred = NEW zcl_az_token_credential_fake( ).
    " dual seam: mock transport AND a fake credential (no live AAD / Azure).
    mo_cut  = NEW zcl_az_blob_udk_sas(
                iv_account_name = 'acct'
                io_credential   = mo_cred
                io_http_client  = mo_http ).
  ENDMETHOD.

  METHOD sample_key_xml.
    rv = `<?xml version="1.0" encoding="utf-8"?>`
      && `<UserDelegationKey>`
      && `<SignedOid>oid-1</SignedOid>`
      && `<SignedTid>tid-1</SignedTid>`
      && `<SignedStart>2026-07-10T10:00:00Z</SignedStart>`
      && `<SignedExpiry>2026-07-11T10:00:00Z</SignedExpiry>`
      && `<SignedService>b</SignedService>`
      && `<SignedVersion>2023-11-03</SignedVersion>`
      && `<Value>rL0Y20zC+Fzt72VPzMSk2A==</Value>`
      && `</UserDelegationKey>`.
  ENDMETHOD.

  METHOD parses_delegation_key.
    mo_http->add_response( iv_status = 200 iv_content_type = 'application/xml'
                           iv_body = sample_key_xml( ) ).

    DATA(ls) = mo_cut->get_user_delegation_key(
      iv_start  = '2026-07-10T10:00:00Z'
      iv_expiry = '2026-07-11T10:00:00Z' ).

    cl_abap_unit_assert=>assert_equals( exp = 'oid-1' act = ls-signed_oid ).
    cl_abap_unit_assert=>assert_equals( exp = 'tid-1' act = ls-signed_tid ).
    cl_abap_unit_assert=>assert_equals( exp = '2026-07-10T10:00:00Z' act = ls-signed_start ).
    cl_abap_unit_assert=>assert_equals( exp = '2026-07-11T10:00:00Z' act = ls-signed_expiry ).
    cl_abap_unit_assert=>assert_equals( exp = 'b' act = ls-signed_service ).
    cl_abap_unit_assert=>assert_equals( exp = '2023-11-03' act = ls-signed_version ).
    cl_abap_unit_assert=>assert_equals( exp = 'rL0Y20zC+Fzt72VPzMSk2A==' act = ls-value ).
  ENDMETHOD.

  METHOD builds_getkey_request.
    mo_http->add_response( iv_status = 200 iv_content_type = 'application/xml'
                           iv_body = sample_key_xml( ) ).

    mo_cut->get_user_delegation_key(
      iv_start  = '2026-07-10T10:00:00Z'
      iv_expiry = '2026-07-11T10:00:00Z' ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'POST' act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_char_cp(
      exp = '*acct.blob.core.windows.net/?restype=service&comp=userdelegationkey*'
      act = lo_req->mv_url ).
    cl_abap_unit_assert=>assert_char_cp(
      exp = '*<KeyInfo><Start>2026-07-10T10:00:00Z</Start><Expiry>2026-07-11T10:00:00Z</Expiry></KeyInfo>*'
      act = lo_req->mv_body
      msg = 'KeyInfo body not built' ).
    READ TABLE lo_req->mt_headers
      WITH KEY table_line = 'x-ms-version:2023-11-03' TRANSPORTING NO FIELDS.
    cl_abap_unit_assert=>assert_subrc( msg = 'x-ms-version header missing' ).
  ENDMETHOD.

  METHOD uses_storage_scope.
    mo_http->add_response( iv_status = 200 iv_content_type = 'application/xml'
                           iv_body = sample_key_xml( ) ).

    mo_cut->get_user_delegation_key(
      iv_start = '2026-07-10T10:00:00Z' iv_expiry = '2026-07-11T10:00:00Z' ).

    cl_abap_unit_assert=>assert_equals(
      exp = 'https://storage.azure.com/.default'
      act = mo_cred->get_scope_seen( ) ).
  ENDMETHOD.

  METHOD http_error_raises.
    mo_http->add_response( iv_status = 403 iv_content_type = 'application/xml'
      iv_body = `<Error><Code>AuthorizationFailure</Code></Error>` ).

    TRY.
        mo_cut->get_user_delegation_key(
          iv_start = '2026-07-10T10:00:00Z' iv_expiry = '2026-07-11T10:00:00Z' ).
        cl_abap_unit_assert=>fail( 'expected zcx_azure for HTTP 403' ).
      CATCH zcx_azure.
        " expected
    ENDTRY.
  ENDMETHOD.

  METHOD create_client_appends_sas.
    " one mock serves both the get-key POST and the returned client's list call.
    mo_http->add_response( iv_status = 200 iv_content_type = 'application/xml'
                           iv_body = sample_key_xml( ) ).
    mo_http->add_response( iv_status = 200 iv_content_type = 'application/xml'
                           iv_body = `<EnumerationResults><Blobs/></EnumerationResults>` ).

    DATA(lo_client) = mo_cut->create_blob_client(
      iv_container   = 'c1'
      iv_permissions = 'rl'
      iv_start       = '2026-07-10T10:00:00Z'
      iv_expiry      = '2026-07-11T10:00:00Z'
      io_http_client = mo_http ).

    lo_client->list_blobs( iv_container = 'c1' ).

    " the SAS (signature + signed-key id) is appended to the data request URL
    DATA(lv_url) = mo_http->get_last_request( )->mv_url.
    cl_abap_unit_assert=>assert_char_cp( exp = '*sig=*'   act = lv_url ).
    cl_abap_unit_assert=>assert_char_cp( exp = '*skoid=*' act = lv_url ).
    cl_abap_unit_assert=>assert_char_cp( exp = '*sr=c*'   act = lv_url ).
  ENDMETHOD.

ENDCLASS.


"----------------------------------------------------------------------
" Phase 2: SAS signing. Pure (no HTTP) - a fixed delegation key drives
" deterministic StringToSign + query-string assertions.
"----------------------------------------------------------------------
CLASS ltc_udk_sign DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    DATA mo_cut TYPE REF TO zcl_az_blob_udk_sas.

    METHODS setup.
    METHODS key RETURNING VALUE(rs) TYPE zcl_az_blob_xml_deserializer=>ty_user_delegation_key.

    "! Canonicalized resource for a blob vs a container.
    METHODS canonical_resource_blob      FOR TESTING.
    METHODS canonical_resource_container FOR TESTING.
    "! Exact StringToSign layout (field order + mandatory empty lines).
    METHODS string_to_sign_layout        FOR TESTING.
    "! A blob SAS carries sr=b and all required + signed-key params.
    METHODS blob_sas_required_params     FOR TESTING RAISING zcx_azure.
    "! A container SAS carries sr=c.
    METHODS container_sas_uses_sr_c      FOR TESTING RAISING zcx_azure.
    "! Same inputs always yield the same SAS (deterministic signature).
    METHODS blob_sas_is_deterministic    FOR TESTING RAISING zcx_azure.
    "! Reserved characters in values (':' in timestamps) are percent-encoded.
    METHODS sas_values_url_encoded       FOR TESTING RAISING zcx_azure.

ENDCLASS.


CLASS ltc_udk_sign IMPLEMENTATION.

  METHOD setup.
    " account name only matters for the canonicalized resource; no HTTP is made.
    mo_cut = NEW zcl_az_blob_udk_sas(
               iv_account_name = 'acct'
               io_credential   = NEW zcl_az_token_credential_fake( ) ).
  ENDMETHOD.

  METHOD key.
    rs-signed_oid     = 'oid-1'.
    rs-signed_tid     = 'tid-1'.
    rs-signed_start   = '2026-07-10T10:00:00Z'.
    rs-signed_expiry  = '2026-07-11T10:00:00Z'.
    rs-signed_service = 'b'.
    rs-signed_version = '2023-11-03'.
    " a valid base64 key (RFC 4231 20 x 0x0b) so HMAC signing succeeds
    rs-value          = 'CwsLCwsLCwsLCwsLCwsLCwsLCws='.
  ENDMETHOD.

  METHOD canonical_resource_blob.
    cl_abap_unit_assert=>assert_equals(
      exp = '/blob/acct/c1/photo.png'
      act = zcl_az_blob_udk_sas=>canonicalized_resource(
              iv_account = 'acct' iv_container = 'c1' iv_blob = 'photo.png' ) ).
  ENDMETHOD.

  METHOD canonical_resource_container.
    cl_abap_unit_assert=>assert_equals(
      exp = '/blob/acct/c1'
      act = zcl_az_blob_udk_sas=>canonicalized_resource(
              iv_account = 'acct' iv_container = 'c1' ) ).
  ENDMETHOD.

  METHOD string_to_sign_layout.
    DATA(lf) = cl_abap_char_utilities=>newline.

    DATA(lv_exp) =
           |r{ lf }|                          " signedPermissions
        && |{ lf }|                           " signedStart (empty)
        && |2026-07-11T10:00:00Z{ lf }|       " signedExpiry
        && |/blob/acct/c1/photo.png{ lf }|    " canonicalizedResource
        && |oid-1{ lf }|                       " skoid
        && |tid-1{ lf }|                       " sktid
        && |2026-07-10T10:00:00Z{ lf }|       " skt
        && |2026-07-11T10:00:00Z{ lf }|       " ske
        && |b{ lf }|                           " sks
        && |2023-11-03{ lf }|                  " skv
        && |{ lf }|                            " saoid
        && |{ lf }|                            " suoid
        && |{ lf }|                            " scid
        && |{ lf }|                            " signedIP
        && |https{ lf }|                       " signedProtocol
        && |2023-11-03{ lf }|                  " signedVersion
        && |b{ lf }|                           " signedResource
        && |{ lf }|                            " snapshot time
        && |{ lf }|                            " encryption scope
        && |{ lf }|                            " rscc
        && |{ lf }|                            " rscd
        && |{ lf }|                            " rsce
        && |{ lf }|                            " rscl
        && ||.                                 " rsct

    cl_abap_unit_assert=>assert_equals(
      exp = lv_exp
      act = zcl_az_blob_udk_sas=>build_sas_string_to_sign(
              is_delegation_key = key( )
              iv_permissions    = 'r'
              iv_start          = ''
              iv_expiry         = '2026-07-11T10:00:00Z'
              iv_resource_path  = '/blob/acct/c1/photo.png'
              iv_ip             = ''
              iv_protocol       = 'https'
              iv_version        = '2023-11-03'
              iv_resource       = 'b' ) ).
  ENDMETHOD.

  METHOD blob_sas_required_params.
    DATA(lv_sas) = mo_cut->generate_blob_sas(
      is_delegation_key = key( )
      iv_container      = 'c1'
      iv_blob           = 'photo.png'
      iv_permissions    = 'r'
      iv_expiry         = '2026-07-11T10:00:00Z' ).

    cl_abap_unit_assert=>assert_char_cp( exp = '*sr=b*'      act = lv_sas ).
    cl_abap_unit_assert=>assert_char_cp( exp = '*sv=*'       act = lv_sas ).
    cl_abap_unit_assert=>assert_char_cp( exp = '*sp=r*'      act = lv_sas ).
    cl_abap_unit_assert=>assert_char_cp( exp = '*se=*'       act = lv_sas ).
    cl_abap_unit_assert=>assert_char_cp( exp = '*skoid=oid-1*' act = lv_sas ).
    cl_abap_unit_assert=>assert_char_cp( exp = '*sktid=tid-1*' act = lv_sas ).
    cl_abap_unit_assert=>assert_char_cp( exp = '*sks=b*'     act = lv_sas ).
    cl_abap_unit_assert=>assert_char_cp( exp = '*skv=*'      act = lv_sas ).
    cl_abap_unit_assert=>assert_char_cp( exp = '*sig=*'      act = lv_sas ).
  ENDMETHOD.

  METHOD container_sas_uses_sr_c.
    DATA(lv_sas) = mo_cut->generate_blob_sas(
      is_delegation_key = key( )
      iv_container      = 'c1'
      iv_permissions    = 'rl'
      iv_expiry         = '2026-07-11T10:00:00Z' ).

    cl_abap_unit_assert=>assert_char_cp( exp = '*sr=c*'  act = lv_sas ).
    cl_abap_unit_assert=>assert_char_cp( exp = '*sp=rl*' act = lv_sas ).
  ENDMETHOD.

  METHOD blob_sas_is_deterministic.
    cl_abap_unit_assert=>assert_equals(
      exp = mo_cut->generate_blob_sas( is_delegation_key = key( ) iv_container = 'c1'
              iv_blob = 'b.txt' iv_permissions = 'r' iv_expiry = '2026-07-11T10:00:00Z' )
      act = mo_cut->generate_blob_sas( is_delegation_key = key( ) iv_container = 'c1'
              iv_blob = 'b.txt' iv_permissions = 'r' iv_expiry = '2026-07-11T10:00:00Z' ) ).
  ENDMETHOD.

  METHOD sas_values_url_encoded.
    DATA(lv_sas) = mo_cut->generate_blob_sas(
      is_delegation_key = key( )
      iv_container      = 'c1'
      iv_blob           = 'b.txt'
      iv_permissions    = 'r'
      iv_expiry         = '2026-07-11T10:00:00Z' ).

    " every value is percent-encoded, so no raw reserved ':' (from the ISO 8601
    " timestamps) or '/' '+' (from the base64 signature) may leak into the SAS.
    " ('=' and '&' are the query-string structural separators, so not checked.)
    cl_abap_unit_assert=>assert_false(
      act = boolc( lv_sas CA ':/+' )
      msg = 'reserved characters must be percent-encoded in the SAS query string' ).
  ENDMETHOD.

ENDCLASS.
