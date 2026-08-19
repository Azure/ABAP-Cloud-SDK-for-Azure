* Copyright (c) Microsoft Corporation.
* Licensed under the MIT license.

CLASS zcl_az_blob_udk_sas DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.

    "! Builder for a User Delegation SAS (UDK SAS) on Azure Blob storage.
    "! Unlike an account-key SAS, a UDK SAS is signed with a key derived from an
    "! Azure AD identity, so every generated SAS is traceable to that identity
    "! (skoid/sktid) and needs no account key
    METHODS constructor
      IMPORTING
        iv_account_name TYPE string
        io_credential   TYPE REF TO zif_az_token_credential
        iv_version      TYPE string DEFAULT '2023-11-03'
        iv_max_retries  TYPE i DEFAULT 3
        io_http_client  TYPE REF TO zif_az_http_client OPTIONAL.

    "! Request a user delegation key valid between iv_start and iv_expiry
    "! (ISO 8601 UTC, e.g. '2026-07-10T10:00:00Z'; Azure caps the lifetime at
    "! 7 days). The returned key (skoid, sktid,
    "! skt, ske, sks, skv, value) is the input to UDK SAS signing.
    METHODS get_user_delegation_key
      IMPORTING
        iv_start      TYPE string
        iv_expiry     TYPE string
      RETURNING
        VALUE(rs_key) TYPE zcl_az_blob_xml_deserializer=>ty_user_delegation_key
      RAISING
        zcx_azure.

    "! Generate a User Delegation SAS query string for a container or a
    "! single blob, signed with a delegation key from get_user_delegation_key.
    "! Pass iv_blob empty for a CONTAINER-level SAS (sr='c'); supply it for a
    "! BLOB-level SAS (sr='b'). iv_permissions must be in Azure's canonical order
    "! (e.g. 'r', 'rw', 'racwdl') and is used verbatim for both the signature and
    "! the sp= parameter. Times are ISO 8601 UTC. The returned string has no
    "! leading '?'.
    METHODS generate_blob_sas
      IMPORTING
        is_delegation_key TYPE zcl_az_blob_xml_deserializer=>ty_user_delegation_key
        iv_container      TYPE string
        iv_permissions    TYPE string
        iv_expiry         TYPE string
        iv_blob           TYPE string OPTIONAL
        iv_start          TYPE string OPTIONAL
        iv_protocol       TYPE string DEFAULT 'https'
        iv_ip             TYPE string OPTIONAL
      RETURNING
        VALUE(rv_sas)     TYPE string
      RAISING
        zcx_azure.

    "! Convenience: acquire a user delegation key, sign a SAS for the
    "! container or blob, and return a ready-to-use blob client authenticated with
    "! that SAS (no account key, no AAD role on the returned client). iv_start and
    "! iv_expiry (ISO 8601 UTC) bound both the delegation key and the SAS. Supply
    "! io_http_client to inject a transport double in unit tests.
    METHODS create_blob_client
      IMPORTING
        iv_container     TYPE string
        iv_permissions   TYPE string
        iv_start         TYPE string
        iv_expiry        TYPE string
        iv_blob          TYPE string OPTIONAL
        iv_protocol      TYPE string DEFAULT 'https'
        iv_ip            TYPE string OPTIONAL
        io_http_client   TYPE REF TO zif_az_http_client OPTIONAL
      RETURNING
        VALUE(ro_client) TYPE REF TO zif_az_blob_service
      RAISING
        zcx_azure.

    "! The canonicalized resource string signed into a blob/container SAS:
    "! "/blob/{account}/{container}" (+ "/{blob}" when iv_blob is supplied).
    CLASS-METHODS canonicalized_resource
      IMPORTING
        iv_account   TYPE string
        iv_container TYPE string
        iv_blob      TYPE string OPTIONAL
      RETURNING
        VALUE(rv)    TYPE string.

    "! Build the StringToSign for a user delegation SAS (service version
    "! 2020-12-06 and later). Optional/unused fields are signed as empty lines,
    "! which is required for the signature to validate.
    CLASS-METHODS build_sas_string_to_sign
      IMPORTING
        is_delegation_key TYPE zcl_az_blob_xml_deserializer=>ty_user_delegation_key
        iv_permissions    TYPE string
        iv_start          TYPE string
        iv_expiry         TYPE string
        iv_resource_path  TYPE string
        iv_ip             TYPE string
        iv_protocol       TYPE string
        iv_version        TYPE string
        iv_resource       TYPE string
      RETURNING
        VALUE(rv)         TYPE string.

  PROTECTED SECTION.
  PRIVATE SECTION.

    DATA mv_account_name TYPE string.
    DATA mv_version      TYPE string.
    DATA mo_pipeline     TYPE REF TO zcl_az_http_pipeline.

    "! Percent-encode a query-parameter value (RFC 3986), so a base64 signature
    "! (+, /, =) and ISO 8601 timestamps (:) survive in the SAS query string.
    CLASS-METHODS url_encode
      IMPORTING iv_value    TYPE string
      RETURNING VALUE(rv)   TYPE string.

ENDCLASS.



CLASS zcl_az_blob_udk_sas IMPLEMENTATION.

  METHOD constructor.

    mv_account_name = iv_account_name.
    mv_version      = iv_version.

    DATA lt_policies TYPE zcl_az_http_pipeline=>tt_policies.

    APPEND NEW zcl_az_policy_retry( iv_max_retries ) TO lt_policies.
    " Get User Delegation Key requires AAD bearer auth (an account key/SAS cannot
    " request it) with the storage data-plane scope.
    APPEND NEW zcl_az_policy_auth(
                 io_credential = io_credential
                 iv_scope      = 'https://storage.azure.com/.default' ) TO lt_policies.
    APPEND NEW zcl_az_policy_logging( ) TO lt_policies.
    " Transport is injectable (io_http_client) for unit tests.
    APPEND NEW zcl_az_pipeline_trans_policy(
                 COND #( WHEN io_http_client IS BOUND
                         THEN io_http_client
                         ELSE NEW zcl_az_http_client( ) ) ) TO lt_policies.

    mo_pipeline = NEW zcl_az_http_pipeline( lt_policies ).

  ENDMETHOD.


  METHOD get_user_delegation_key.

    DATA(lo_request) = NEW zcl_az_http_request( ).
    lo_request->mv_method = 'POST'.
    lo_request->mv_url    =
      |https://{ mv_account_name }.blob.core.windows.net/?restype=service&comp=userdelegationkey|.
    lo_request->mv_body   =
      |<?xml version="1.0" encoding="utf-8"?>| &&
      |<KeyInfo><Start>{ iv_start }</Start><Expiry>{ iv_expiry }</Expiry></KeyInfo>|.

    APPEND |x-ms-version:{ mv_version }| TO lo_request->mt_headers.
    APPEND |Content-Type:application/xml| TO lo_request->mt_headers.

    DATA(lo_response) = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING
          iv_message = |Get User Delegation Key failed (HTTP { lo_response->get_status_code( ) }): | &&
                       |{ lo_response->get_body( ) }|.
    ENDIF.

    TRY.
        " The response is application/xml, captured by the transport as a string
        " (textual content-type) or, defensively, as raw bytes.
        DATA lv_xml TYPE xstring.
        DATA(lv_body) = lo_response->get_body( ).
        IF lv_body IS NOT INITIAL.
          lv_xml = cl_abap_conv_codepage=>create_out( codepage = 'UTF-8' )->convert( lv_body ).
        ELSE.
          lv_xml = lo_response->get_body_bin( ).
        ENDIF.

        rs_key = zcl_az_blob_xml_deserializer=>deserialize_user_deleg_key( lv_xml ).

      CATCH zcx_azure INTO DATA(lx_az).
        RAISE EXCEPTION lx_az.
      CATCH cx_root INTO DATA(lx_root).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process user delegation key response: { lx_root->get_text( ) }|
            previous   = lx_root.
    ENDTRY.

  ENDMETHOD.


  METHOD canonicalized_resource.
    rv = |/blob/{ iv_account }/{ iv_container }|.
    IF iv_blob IS NOT INITIAL.
      rv = rv && |/{ iv_blob }|.
    ENDIF.
  ENDMETHOD.


  METHOD build_sas_string_to_sign.

    DATA(lf) = cl_abap_char_utilities=>newline.

    " User delegation SAS StringToSign (service version 2020-12-06 and later).
    " Unused optional fields (saoid, suoid, scid, snapshot time, encryption
    " scope, response-override headers rscc/rscd/rsce/rscl/rsct) are signed as
    " empty lines - their presence is mandatory for the signature to validate.
    rv =        iv_permissions              && lf   " signedPermissions
         &&     iv_start                    && lf   " signedStart
         &&     iv_expiry                   && lf   " signedExpiry
         &&     iv_resource_path            && lf   " canonicalizedResource
         &&     is_delegation_key-signed_oid     && lf   " signedKeyObjectId (skoid)
         &&     is_delegation_key-signed_tid     && lf   " signedKeyTenantId (sktid)
         &&     is_delegation_key-signed_start   && lf   " signedKeyStart    (skt)
         &&     is_delegation_key-signed_expiry  && lf   " signedKeyExpiry   (ske)
         &&     is_delegation_key-signed_service && lf   " signedKeyService  (sks)
         &&     is_delegation_key-signed_version && lf   " signedKeyVersion  (skv)
         &&     ``                          && lf   " signedAuthorizedUserObjectId (saoid)
         &&     ``                          && lf   " signedUnauthorizedUserObjectId (suoid)
         &&     ``                          && lf   " signedCorrelationId (scid)
         &&     iv_ip                       && lf   " signedIP
         &&     iv_protocol                 && lf   " signedProtocol
         &&     iv_version                  && lf   " signedVersion
         &&     iv_resource                 && lf   " signedResource
         &&     ``                          && lf   " signedSnapshotTime
         &&     ``                          && lf   " signedEncryptionScope
         &&     ``                          && lf   " rscc (Cache-Control)
         &&     ``                          && lf   " rscd (Content-Disposition)
         &&     ``                          && lf   " rsce (Content-Encoding)
         &&     ``                          && lf   " rscl (Content-Language)
         &&     ``.                                 " rsct (Content-Type)

  ENDMETHOD.


  METHOD url_encode.
    rv = escape( val = iv_value format = cl_abap_format=>e_uri_full ).
  ENDMETHOD.


  METHOD generate_blob_sas.

    " Container-level SAS (sr='c') unless a blob name is supplied (sr='b').
    DATA(lv_resource) = COND string( WHEN iv_blob IS INITIAL THEN 'c' ELSE 'b' ).

    DATA(lv_resource_path) = canonicalized_resource(
      iv_account   = mv_account_name
      iv_container = iv_container
      iv_blob      = iv_blob ).

    DATA(lv_sts) = build_sas_string_to_sign(
      is_delegation_key = is_delegation_key
      iv_permissions    = iv_permissions
      iv_start          = iv_start
      iv_expiry         = iv_expiry
      iv_resource_path  = lv_resource_path
      iv_ip             = iv_ip
      iv_protocol       = iv_protocol
      iv_version        = mv_version
      iv_resource       = lv_resource ).

    DATA(lv_sig) = zcl_az_crypto=>hmac_sha256_b64(
      iv_key_base64 = is_delegation_key-value
      iv_data       = lv_sts ).

    " Assemble the SAS query string (values percent-encoded). skoid/sktid/skt/
    " ske/sks/skv identify the AAD-derived signing key, making the SAS traceable.
    rv_sas = |sv={ url_encode( mv_version ) }|
          && |&sr={ lv_resource }|
          && |&sp={ url_encode( iv_permissions ) }|
          && |&se={ url_encode( iv_expiry ) }|.

    IF iv_start IS NOT INITIAL.
      rv_sas = rv_sas && |&st={ url_encode( iv_start ) }|.
    ENDIF.

    rv_sas = rv_sas
          && |&spr={ url_encode( iv_protocol ) }|.

    IF iv_ip IS NOT INITIAL.
      rv_sas = rv_sas && |&sip={ url_encode( iv_ip ) }|.
    ENDIF.

    rv_sas = rv_sas
          && |&skoid={ url_encode( is_delegation_key-signed_oid ) }|
          && |&sktid={ url_encode( is_delegation_key-signed_tid ) }|
          && |&skt={ url_encode( is_delegation_key-signed_start ) }|
          && |&ske={ url_encode( is_delegation_key-signed_expiry ) }|
          && |&sks={ url_encode( is_delegation_key-signed_service ) }|
          && |&skv={ url_encode( is_delegation_key-signed_version ) }|
          && |&sig={ url_encode( lv_sig ) }|.

  ENDMETHOD.


  METHOD create_blob_client.

    "Acquire a delegation key for the requested window.
    DATA(ls_key) = get_user_delegation_key(
      iv_start  = iv_start
      iv_expiry = iv_expiry ).

    " Sign a SAS for the container/blob.
    DATA(lv_sas) = generate_blob_sas(
      is_delegation_key = ls_key
      iv_container      = iv_container
      iv_permissions    = iv_permissions
      iv_expiry         = iv_expiry
      iv_blob           = iv_blob
      iv_start          = iv_start
      iv_protocol       = iv_protocol
      iv_ip             = iv_ip ).

    " Create a blob client that authenticates with the SAS (zcl_az_policy_sas).
    ro_client = NEW zcl_az_blob_client(
      iv_account_name = mv_account_name
      iv_sas_token    = lv_sas
      io_http_client  = io_http_client ).

  ENDMETHOD.

ENDCLASS.
