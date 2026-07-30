*"* use this source file for your ABAP unit test classes

CLASS ltc_managed_identity_cred DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    DATA mo_http TYPE REF TO zcl_az_http_client_mock.
    DATA mo_cut  TYPE REF TO zcl_az_managed_identity_cred.

    METHODS setup.
    "! 200 + token JSON from IMDS -> access token returned.
    METHODS returns_token_on_success   FOR TESTING RAISING zcx_azure.
    "! GETs the IMDS endpoint with the mandatory Metadata:true header + resource.
    METHODS gets_imds_with_metadata    FOR TESTING RAISING zcx_azure.
    "! A user-assigned identity adds client_id to the query string.
    METHODS user_assigned_adds_client  FOR TESTING RAISING zcx_azure.
    "! Non-2xx from IMDS -> zcx_az_auth_error.
    METHODS http_error_raises          FOR TESTING.
    "! Empty scope is rejected before any HTTP call.
    METHODS empty_scope_raises         FOR TESTING.
ENDCLASS.


CLASS ltc_managed_identity_cred IMPLEMENTATION.

  METHOD setup.
    mo_http = NEW zcl_az_http_client_mock( ).
    mo_cut  = NEW zcl_az_managed_identity_cred( io_http_client = mo_http ).
  ENDMETHOD.

  METHOD returns_token_on_success.
    mo_http->add_response(
      iv_status = 200
      iv_body   = `{"access_token":"imds-tok","token_type":"Bearer","expires_in":3599}` ).

    DATA(lo_token) = mo_cut->zif_az_token_credential~get_token(
      iv_scope = 'https://management.azure.com/' ).

    cl_abap_unit_assert=>assert_equals( exp = 'imds-tok' act = lo_token->get_token( ) ).
  ENDMETHOD.

  METHOD gets_imds_with_metadata.
    mo_http->add_response( iv_status = 200
      iv_body = `{"access_token":"t","token_type":"Bearer","expires_in":1}` ).

    mo_cut->zif_az_token_credential~get_token( iv_scope = 'https://storage.azure.com/' ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'GET' act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_char_cp(
      exp = '*169.254.169.254/metadata/identity/oauth2/token*resource=https://storage.azure.com/*'
      act = lo_req->mv_url ).
    READ TABLE lo_req->mt_headers WITH KEY table_line = 'Metadata:true' TRANSPORTING NO FIELDS.
    cl_abap_unit_assert=>assert_subrc( msg = 'Metadata:true header missing' ).
  ENDMETHOD.

  METHOD user_assigned_adds_client.
    mo_cut->set_client_id( 'uami-guid' ).
    mo_http->add_response( iv_status = 200
      iv_body = `{"access_token":"t","token_type":"Bearer","expires_in":1}` ).

    mo_cut->zif_az_token_credential~get_token( iv_scope = 'scope' ).

    cl_abap_unit_assert=>assert_char_cp(
      exp = '*client_id=uami-guid*'
      act = mo_http->get_last_request( )->mv_url ).
  ENDMETHOD.

  METHOD http_error_raises.
    mo_http->add_response( iv_status = 400 iv_body = `{"error":"bad"}` ).
    TRY.
        mo_cut->zif_az_token_credential~get_token( iv_scope = 'scope' ).
        cl_abap_unit_assert=>fail( 'expected zcx_az_auth_error' ).
      CATCH zcx_az_auth_error.
    ENDTRY.
  ENDMETHOD.

  METHOD empty_scope_raises.
    TRY.
        mo_cut->zif_az_token_credential~get_token( iv_scope = '' ).
        cl_abap_unit_assert=>fail( 'expected zcx_az_auth_error for empty scope' ).
      CATCH zcx_az_auth_error.
    ENDTRY.
    cl_abap_unit_assert=>assert_equals( exp = 0 act = mo_http->get_call_count( ) ).
  ENDMETHOD.

ENDCLASS.
