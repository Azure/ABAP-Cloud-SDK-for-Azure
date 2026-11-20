* Copyright (c) Microsoft Corporation.
* Licensed under the MIT license.

CLASS zcl_az_blob_client DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.

    INTERFACES zif_az_blob_service.
    ALIASES list_containers FOR zif_az_blob_service~list_containers.
    ALIASES list_blobs      FOR zif_az_blob_service~list_blobs.
    ALIASES download_blob   FOR zif_az_blob_service~download_blob.
    ALIASES upload_blob     FOR zif_az_blob_service~upload_blob.

    METHODS constructor
      IMPORTING
        iv_account_name  TYPE string
        io_credential    TYPE REF TO zif_az_token_credential OPTIONAL
        iv_sas_token     TYPE string OPTIONAL
        iv_account_key   TYPE string OPTIONAL
        it_extra_headers TYPE tihttpnvp OPTIONAL
        iv_max_retries   TYPE i DEFAULT 3
        io_http_client   TYPE REF TO zif_az_http_client OPTIONAL.

  PROTECTED SECTION.
  PRIVATE SECTION.

    CONSTANTS c_api_version TYPE string VALUE '2023-11-03'.

    DATA mo_pipeline      TYPE REF TO zcl_az_http_pipeline.
    DATA mv_uri_prefix    TYPE string.
    DATA mt_extra_headers TYPE tihttpnvp.

    METHODS new_request
      IMPORTING iv_method TYPE string iv_url TYPE string
      RETURNING VALUE(ro_request) TYPE REF TO zcl_az_http_request.
    METHODS send_and_check
      IMPORTING io_request TYPE REF TO zcl_az_http_request
      RETURNING VALUE(ro_response) TYPE REF TO zcl_az_http_response
      RAISING zcx_azure.
    METHODS to_xstring
      IMPORTING iv_string TYPE string
      RETURNING VALUE(rv_xstring) TYPE xstring.

ENDCLASS.


CLASS zcl_az_blob_client IMPLEMENTATION.

  METHOD constructor.

    DATA lt_policies TYPE zcl_az_http_pipeline=>tt_policies.

    mv_uri_prefix    = |https://{ iv_account_name }.blob.core.windows.net|.
    mt_extra_headers = it_extra_headers.

    APPEND NEW zcl_az_policy_retry( iv_max_retries ) TO lt_policies.
    " Authentication precedence: a SAS query string, else a Shared Key (account
    " key) signature, else the AAD bearer credential (io_credential).
    IF iv_sas_token IS NOT INITIAL.
      APPEND NEW zcl_az_policy_sas( iv_sas_token ) TO lt_policies.
    ELSEIF iv_account_key IS NOT INITIAL.
      APPEND NEW zcl_az_policy_shared_key(
                   iv_account_name = iv_account_name
                   iv_account_key  = iv_account_key ) TO lt_policies.
    ELSE.
      APPEND NEW zcl_az_policy_auth(
                   io_credential = io_credential
                   iv_scope      = 'https://storage.azure.com/.default' ) TO lt_policies.
    ENDIF.
    APPEND NEW zcl_az_policy_logging( ) TO lt_policies.
    " Transport is injectable (io_http_client) for unit tests.
    APPEND NEW zcl_az_pipeline_trans_policy(
                 COND #( WHEN io_http_client IS BOUND
                         THEN io_http_client
                         ELSE NEW zcl_az_http_client( ) ) ) TO lt_policies.

    mo_pipeline = NEW zcl_az_http_pipeline( lt_policies ).

  ENDMETHOD.


METHOD zif_az_blob_service~list_containers.

  DATA(lo_request) = new_request(
    iv_method = 'GET'
    iv_url    = |{ mv_uri_prefix }/?comp=list| ).

  IF iv_prefix IS NOT INITIAL.
    lo_request->mv_url = |{ lo_request->mv_url }&prefix={ iv_prefix }|.
  ENDIF.
  IF iv_max_results > 0.
    lo_request->mv_url = |{ lo_request->mv_url }&maxresults={ iv_max_results }|.
  ENDIF.
  IF iv_marker IS NOT INITIAL.
    lo_request->mv_url = |{ lo_request->mv_url }&marker={ iv_marker }|.
  ENDIF.

  DATA(lo_response) = send_and_check( lo_request ).

  ro_result = zcl_az_blob_xml_deserializer=>deserialize_list_containers(
                to_xstring( lo_response->get_body( ) ) ).

ENDMETHOD.



METHOD zif_az_blob_service~list_blobs.

  IF iv_container IS INITIAL.
    RAISE EXCEPTION TYPE zcx_az_service_error
      EXPORTING iv_message = |list_blobs: container name is required.|.
  ENDIF.

  DATA(lo_request) = new_request(
    iv_method = 'GET'
    iv_url    = |{ mv_uri_prefix }/{ iv_container }?restype=container&comp=list| ).

  IF iv_prefix IS NOT INITIAL.
    lo_request->mv_url = |{ lo_request->mv_url }&prefix={ iv_prefix }|.
  ENDIF.
  IF iv_delimiter IS NOT INITIAL.
    lo_request->mv_url = |{ lo_request->mv_url }&delimiter={ iv_delimiter }|.
  ENDIF.
  IF iv_max_results > 0.
    lo_request->mv_url = |{ lo_request->mv_url }&maxresults={ iv_max_results }|.
  ENDIF.
  IF iv_marker IS NOT INITIAL.
    lo_request->mv_url = |{ lo_request->mv_url }&marker={ iv_marker }|.
  ENDIF.

  DATA(lo_response) = send_and_check( lo_request ).

  ro_result = zcl_az_blob_xml_deserializer=>deserialize_list_blobs(
                to_xstring( lo_response->get_body( ) ) ).

ENDMETHOD.



METHOD zif_az_blob_service~download_blob.

  IF iv_container IS INITIAL OR iv_blob_name IS INITIAL.
    RAISE EXCEPTION TYPE zcx_az_service_error
      EXPORTING iv_message = |download_blob: container and blob name are required.|.
  ENDIF.

  DATA(lo_request) = new_request(
    iv_method = 'GET'
    iv_url    = |{ mv_uri_prefix }/{ iv_container }/{ iv_blob_name }| ).

  DATA(lo_response) = send_and_check( lo_request ).

  ro_result = NEW zcl_az_blob_content( ).

  " The content-type-aware transport stores binary payloads in mv_body_bin and
  " textual ones in mv_body; for a download we always want the bytes.
  IF lo_response->get_body_bin( ) IS NOT INITIAL.
    ro_result->mv_content = lo_response->get_body_bin( ).
  ELSE.
    ro_result->mv_content = to_xstring( lo_response->get_body( ) ).
  ENDIF.

  ro_result->mv_content_type  = lo_response->get_header( 'Content-Type' ).
  ro_result->mv_etag          = lo_response->get_header( 'ETag' ).
  ro_result->mv_last_modified = lo_response->get_header( 'Last-Modified' ).

  DATA(lv_len) = lo_response->get_header( 'Content-Length' ).
  IF lv_len IS NOT INITIAL AND lv_len CO '0123456789'.
    ro_result->mv_content_length = lv_len.
  ENDIF.

ENDMETHOD.



METHOD zif_az_blob_service~upload_blob.

  IF iv_container IS INITIAL OR iv_blob_name IS INITIAL.
    RAISE EXCEPTION TYPE zcx_az_service_error
      EXPORTING iv_message = |upload_blob: container and blob name are required.|.
  ENDIF.

  DATA(lo_request) = new_request(
    iv_method = 'PUT'
    iv_url    = |{ mv_uri_prefix }/{ iv_container }/{ iv_blob_name }| ).

  APPEND 'x-ms-blob-type:BlockBlob' TO lo_request->mt_headers.
  APPEND |Content-Type:{ iv_content_type }| TO lo_request->mt_headers.
  lo_request->mv_body_bin = iv_content.

  DATA(lo_response) = send_and_check( lo_request ).

  ro_result = NEW zcl_az_upload_blob_result( ).
  ro_result->mv_etag          = lo_response->get_header( 'ETag' ).
  ro_result->mv_last_modified = lo_response->get_header( 'Last-Modified' ).
  ro_result->mv_content_md5   = lo_response->get_header( 'Content-MD5' ).
  ro_result->mv_version_id    = lo_response->get_header( 'x-ms-version-id' ).

ENDMETHOD.



METHOD new_request.
  ro_request = NEW zcl_az_http_request( ).
  ro_request->mv_method = iv_method.
  ro_request->mv_url    = iv_url.
  APPEND |x-ms-version:{ c_api_version }| TO ro_request->mt_headers.
ENDMETHOD.



METHOD send_and_check.
  ro_response = mo_pipeline->send( io_request ).
  IF ro_response->is_success( ) <> abap_true.
    RAISE EXCEPTION TYPE zcx_az_service_error
      EXPORTING iv_message = ro_response->get_body( ).
  ENDIF.
ENDMETHOD.



METHOD to_xstring.
  rv_xstring = cl_abap_conv_codepage=>create_out( codepage = 'UTF-8' )->convert( iv_string ).
ENDMETHOD.


  METHOD zif_az_blob_service~service_setproperties.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/?restype=service&comp=properties'.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    APPEND 'Content-Type:application/xml' TO lo_request->mt_headers.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 202. " Success (Accepted)
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~service_getproperties.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'GET'.
    lv_uri = mv_uri_prefix && '/?restype=service&comp=properties'.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Success.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~service_getstatistics.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'GET'.
    lv_uri = mv_uri_prefix && '/?restype=service&comp=stats'.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Success.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~service_listcontainerssegmen.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'GET'.
    lv_uri = mv_uri_prefix && '/?comp=list'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    IF prefix IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |prefix={ prefix }|.
    ENDIF.
    IF marker IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |marker={ marker }|.
    ENDIF.
    IF maxresults IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |maxresults={ maxresults }|.
    ENDIF.
    IF include IS NOT INITIAL.
      DATA(lv_include) = concat_lines_of( table = include sep = `,` ).
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |include={ lv_include }|.
    ENDIF.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Success.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~service_getuserdelegationkey.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'POST'.
    lv_uri = mv_uri_prefix && '/?restype=service&comp=userdelegationkey'.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    APPEND 'Content-Type:application/xml' TO lo_request->mt_headers.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Success.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~service_getaccountinfo.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'GET'.
    lv_uri = mv_uri_prefix && '/?restype=account&comp=properties'.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Success (OK)
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~service_submitbatch.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'POST'.
    lv_uri = mv_uri_prefix && '/?comp=batch'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    APPEND |Content-Length:{ content__length }| TO lo_request->mt_headers.
    APPEND |Content-Type:{ content__type }| TO lo_request->mt_headers.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    APPEND 'Content-Type:application/xml' TO lo_request->mt_headers.
    lo_request->mv_body_bin = body.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Success.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* schema format:file (binary) -> raw bytes in return-raw_body_bin
            return-raw_body_bin = lo_response->get_body_bin( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~service_filterblobs.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'GET'.
    lv_uri = mv_uri_prefix && '/?comp=blobs'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    IF where IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |where={ where }|.
    ENDIF.
    IF marker IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |marker={ marker }|.
    ENDIF.
    IF maxresults IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |maxresults={ maxresults }|.
    ENDIF.
    IF include IS NOT INITIAL.
      DATA(lv_include) = concat_lines_of( table = include sep = `,` ).
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |include={ lv_include }|.
    ENDIF.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Success
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~container_create.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}?restype=container'.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-meta:{ x_ms_meta }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-public-access:{ x_ms_blob_public_access }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |x-ms-default-encryption-scope:{ x_ms_default_encryption_scop }| TO lo_request->mt_headers.
    APPEND |x-ms-deny-encryption-scope-override:{ x_ms_deny_encryption_scope_o }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 201. " Success, Container created.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~container_getproperties.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'GET'.
    lv_uri = mv_uri_prefix && '/{containerName}?restype=container'.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Success
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~container_delete.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'DELETE'.
    lv_uri = mv_uri_prefix && '/{containerName}?restype=container'.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 202. " Accepted
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~container_setmetadata.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}?restype=container&comp=metadata'.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-meta:{ x_ms_meta }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Success
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~container_getaccesspolicy.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'GET'.
    lv_uri = mv_uri_prefix && '/{containerName}?restype=container&comp=acl'.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Success
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~container_setaccesspolicy.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}?restype=container&comp=acl'.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-public-access:{ x_ms_blob_public_access }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    APPEND 'Content-Type:application/xml' TO lo_request->mt_headers.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Success.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~container_restore.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}?restype=container&comp=undelete'.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |x-ms-deleted-container-name:{ x_ms_deleted_container_name }| TO lo_request->mt_headers.
    APPEND |x-ms-deleted-container-version:{ x_ms_deleted_container_versi }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 201. " Created.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~container_rename.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}?restype=container&comp=rename'.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |x-ms-source-container-name:{ x_ms_source_container_name }| TO lo_request->mt_headers.
    APPEND |x-ms-source-lease-id:{ x_ms_source_lease_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Created.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~container_submitbatch.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'POST'.
    lv_uri = mv_uri_prefix && '/{containerName}?restype=container&comp=batch'.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    APPEND |Content-Length:{ content__length }| TO lo_request->mt_headers.
    APPEND |Content-Type:{ content__type }| TO lo_request->mt_headers.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    APPEND 'Content-Type:application/xml' TO lo_request->mt_headers.
    lo_request->mv_body_bin = body.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 202. " Success.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* schema format:file (binary) -> raw bytes in return-raw_body_bin
            return-raw_body_bin = lo_response->get_body_bin( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~container_filterblobs.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'GET'.
    lv_uri = mv_uri_prefix && '/{containerName}?restype=container&comp=blobs'.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    IF where IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |where={ where }|.
    ENDIF.
    IF marker IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |marker={ marker }|.
    ENDIF.
    IF maxresults IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |maxresults={ maxresults }|.
    ENDIF.
    IF include IS NOT INITIAL.
      DATA(lv_include) = concat_lines_of( table = include sep = `,` ).
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |include={ lv_include }|.
    ENDIF.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Success
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~container_acquirelease.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}?comp=lease&restype=container&acquire'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    APPEND |x-ms-lease-action:{ x_ms_lease_action }| TO lo_request->mt_headers.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-duration:{ x_ms_lease_duration }| TO lo_request->mt_headers.
    APPEND |x-ms-proposed-lease-id:{ x_ms_proposed_lease_id }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 201. " The Acquire operation completed successfully.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~container_releaselease.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}?comp=lease&restype=container&release'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    APPEND |x-ms-lease-action:{ x_ms_lease_action }| TO lo_request->mt_headers.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " The Release operation completed successfully.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~container_renewlease.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}?comp=lease&restype=container&renew'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    APPEND |x-ms-lease-action:{ x_ms_lease_action }| TO lo_request->mt_headers.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " The Renew operation completed successfully.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~container_breaklease.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}?comp=lease&restype=container&break'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    APPEND |x-ms-lease-action:{ x_ms_lease_action }| TO lo_request->mt_headers.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-break-period:{ x_ms_lease_break_period }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 202. " The Break operation completed successfully.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~container_changelease.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}?comp=lease&restype=container&change'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    APPEND |x-ms-lease-action:{ x_ms_lease_action }| TO lo_request->mt_headers.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-proposed-lease-id:{ x_ms_proposed_lease_id }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " The Change operation completed successfully.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~container_listblobflatsegmen.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'GET'.
    lv_uri = mv_uri_prefix && '/{containerName}?restype=container&comp=list&flat'.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    IF prefix IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |prefix={ prefix }|.
    ENDIF.
    IF marker IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |marker={ marker }|.
    ENDIF.
    IF maxresults IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |maxresults={ maxresults }|.
    ENDIF.
    IF include IS NOT INITIAL.
      DATA(lv_include) = concat_lines_of( table = include sep = `,` ).
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |include={ lv_include }|.
    ENDIF.
    IF start_from IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |startFrom={ start_from }|.
    ENDIF.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Success.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~container_listblobhierarchys.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'GET'.
    lv_uri = mv_uri_prefix && '/{containerName}?restype=container&comp=list&hierarchy'.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    IF prefix IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |prefix={ prefix }|.
    ENDIF.
    IF delimiter IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |delimiter={ delimiter }|.
    ENDIF.
    IF marker IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |marker={ marker }|.
    ENDIF.
    IF maxresults IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |maxresults={ maxresults }|.
    ENDIF.
    IF include IS NOT INITIAL.
      DATA(lv_include) = concat_lines_of( table = include sep = `,` ).
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |include={ lv_include }|.
    ENDIF.
    IF start_from IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |startFrom={ start_from }|.
    ENDIF.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Success.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~container_getaccountinfo.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'GET'.
    lv_uri = mv_uri_prefix && '/{containerName}?restype=account&comp=properties'.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Success (OK)
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_download.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'GET'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}'.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF snapshot IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |snapshot={ snapshot }|.
    ENDIF.
    IF versionid IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |versionid={ versionid }|.
    ENDIF.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-range:{ x_ms_range }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-range-get-content-md5:{ x_ms_range_get_content_md5 }| TO lo_request->mt_headers.
    APPEND |x-ms-range-get-content-crc64:{ x_ms_range_get_content_crc64 }| TO lo_request->mt_headers.
    APPEND |x-ms-structured-body:{ x_ms_structured_body }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key:{ x_ms_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key-sha256:{ x_ms_encryption_key_sha256 }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-algorithm:{ x_ms_encryption_algorithm }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Returns the content of the entire blob.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* schema format:file (binary) -> raw bytes in return-raw_body_bin
            return-raw_body_bin = lo_response->get_body_bin( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
      WHEN 206. " Returns the content of a specified range of the blob.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* schema format:file (binary) -> raw bytes in return-raw_body_bin
            return-raw_body_bin = lo_response->get_body_bin( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_getproperties.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'HEAD'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}'.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF snapshot IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |snapshot={ snapshot }|.
    ENDIF.
    IF versionid IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |versionid={ versionid }|.
    ENDIF.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key:{ x_ms_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key-sha256:{ x_ms_encryption_key_sha256 }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-algorithm:{ x_ms_encryption_algorithm }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Returns the properties of the blob.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_delete.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'DELETE'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}'.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF snapshot IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |snapshot={ snapshot }|.
    ENDIF.
    IF versionid IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |versionid={ versionid }|.
    ENDIF.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-delete-snapshots:{ x_ms_delete_snapshots }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    IF deletetype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |deletetype={ deletetype }|.
    ENDIF.
    APPEND |x-ms-access-tier-if-modified-since:{ x_ms_access_tier_if_modified }| TO lo_request->mt_headers.
    APPEND |x-ms-access-tier-if-unmodified-since:{ x_ms_access_tier_if_unmodifi }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 202. " The delete request was accepted and the blob will be deleted.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~pageblob_create.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?PageBlob'.
    APPEND |x-ms-blob-type:{ x_ms_blob_type }| TO lo_request->mt_headers.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |Content-Length:{ content__length }| TO lo_request->mt_headers.
    APPEND |x-ms-access-tier:{ x_ms_access_tier }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-type:{ x_ms_blob_content_type }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-encoding:{ x_ms_blob_content_encoding }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-language:{ x_ms_blob_content_language }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-md5:{ x_ms_blob_content_md5 }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-cache-control:{ x_ms_blob_cache_control }| TO lo_request->mt_headers.
    APPEND |x-ms-meta:{ x_ms_meta }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-disposition:{ x_ms_blob_content_dispositio }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key:{ x_ms_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key-sha256:{ x_ms_encryption_key_sha256 }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-algorithm:{ x_ms_encryption_algorithm }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-scope:{ x_ms_encryption_scope }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-length:{ x_ms_blob_content_length }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-sequence-number:{ x_ms_blob_sequence_number }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |x-ms-tags:{ x_ms_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-immutability-policy-until-date:{ x_ms_immutability_policy_unt }| TO lo_request->mt_headers.
    APPEND |x-ms-immutability-policy-mode:{ x_ms_immutability_policy_mod }| TO lo_request->mt_headers.
    APPEND |x-ms-legal-hold:{ x_ms_legal_hold }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 201. " The blob was created.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~appendblob_create.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?AppendBlob'.
    APPEND |x-ms-blob-type:{ x_ms_blob_type }| TO lo_request->mt_headers.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |Content-Length:{ content__length }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-type:{ x_ms_blob_content_type }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-encoding:{ x_ms_blob_content_encoding }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-language:{ x_ms_blob_content_language }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-md5:{ x_ms_blob_content_md5 }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-cache-control:{ x_ms_blob_cache_control }| TO lo_request->mt_headers.
    APPEND |x-ms-meta:{ x_ms_meta }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-disposition:{ x_ms_blob_content_dispositio }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key:{ x_ms_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key-sha256:{ x_ms_encryption_key_sha256 }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-algorithm:{ x_ms_encryption_algorithm }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-scope:{ x_ms_encryption_scope }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |x-ms-tags:{ x_ms_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-immutability-policy-until-date:{ x_ms_immutability_policy_unt }| TO lo_request->mt_headers.
    APPEND |x-ms-immutability-policy-mode:{ x_ms_immutability_policy_mod }| TO lo_request->mt_headers.
    APPEND |x-ms-legal-hold:{ x_ms_legal_hold }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 201. " The blob was created.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blockblob_upload.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?BlockBlob'.
    APPEND |x-ms-blob-type:{ x_ms_blob_type }| TO lo_request->mt_headers.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |Content-MD5:{ content_md5 }| TO lo_request->mt_headers.
    APPEND |Content-Length:{ content__length }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-type:{ x_ms_blob_content_type }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-encoding:{ x_ms_blob_content_encoding }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-language:{ x_ms_blob_content_language }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-md5:{ x_ms_blob_content_md5 }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-cache-control:{ x_ms_blob_cache_control }| TO lo_request->mt_headers.
    APPEND |x-ms-meta:{ x_ms_meta }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-disposition:{ x_ms_blob_content_dispositio }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key:{ x_ms_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key-sha256:{ x_ms_encryption_key_sha256 }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-algorithm:{ x_ms_encryption_algorithm }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-scope:{ x_ms_encryption_scope }| TO lo_request->mt_headers.
    APPEND |x-ms-access-tier:{ x_ms_access_tier }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |x-ms-tags:{ x_ms_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-immutability-policy-until-date:{ x_ms_immutability_policy_unt }| TO lo_request->mt_headers.
    APPEND |x-ms-immutability-policy-mode:{ x_ms_immutability_policy_mod }| TO lo_request->mt_headers.
    APPEND |x-ms-legal-hold:{ x_ms_legal_hold }| TO lo_request->mt_headers.
    APPEND |x-ms-content-crc64:{ x_ms_content_crc64 }| TO lo_request->mt_headers.
    APPEND |x-ms-structured-body:{ x_ms_structured_body }| TO lo_request->mt_headers.
    APPEND |x-ms-structured-content-length:{ x_ms_structured_content_leng }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    APPEND 'Content-Type:application/octet-stream' TO lo_request->mt_headers.
    lo_request->mv_body_bin = body.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 201. " The blob was updated.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blockblob_putblobfromurl.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?BlockBlob&fromUrl'.
    APPEND |x-ms-blob-type:{ x_ms_blob_type }| TO lo_request->mt_headers.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |Content-MD5:{ content_md5 }| TO lo_request->mt_headers.
    APPEND |Content-Length:{ content__length }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-type:{ x_ms_blob_content_type }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-encoding:{ x_ms_blob_content_encoding }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-language:{ x_ms_blob_content_language }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-md5:{ x_ms_blob_content_md5 }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-cache-control:{ x_ms_blob_cache_control }| TO lo_request->mt_headers.
    APPEND |x-ms-meta:{ x_ms_meta }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-disposition:{ x_ms_blob_content_dispositio }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key:{ x_ms_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key-sha256:{ x_ms_encryption_key_sha256 }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-algorithm:{ x_ms_encryption_algorithm }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-scope:{ x_ms_encryption_scope }| TO lo_request->mt_headers.
    APPEND |x-ms-access-tier:{ x_ms_access_tier }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-modified-since:{ x_ms_source_if_modified_sinc }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-unmodified-since:{ x_ms_source_if_unmodified_si }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-match:{ x_ms_source_if_match }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-none-match:{ x_ms_source_if_none_match }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-tags:{ x_ms_source_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |x-ms-source-content-md5:{ x_ms_source_content_md5 }| TO lo_request->mt_headers.
    APPEND |x-ms-tags:{ x_ms_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-copy-source:{ x_ms_copy_source }| TO lo_request->mt_headers.
    APPEND |x-ms-copy-source-blob-properties:{ x_ms_copy_source_blob_proper }| TO lo_request->mt_headers.
    APPEND |x-ms-copy-source-authorization:{ x_ms_copy_source_authorizati }| TO lo_request->mt_headers.
    APPEND |x-ms-copy-source-tag-option:{ x_ms_copy_source_tag_option }| TO lo_request->mt_headers.
    APPEND |x-ms-file-request-intent:{ x_ms_file_request_intent }| TO lo_request->mt_headers.
    APPEND |x-ms-source-encryption-key:{ x_ms_source_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-source-encryption-key-sha256:{ x_ms_source_encryption_key_s }| TO lo_request->mt_headers.
    APPEND |x-ms-source-encryption-algorithm:{ x_ms_source_encryption_algor }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 201. " The blob was updated.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_undelete.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=undelete'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " The blob was undeleted successfully.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_setexpiry.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=expiry'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |x-ms-expiry-option:{ x_ms_expiry_option }| TO lo_request->mt_headers.
    APPEND |x-ms-expiry-time:{ x_ms_expiry_time }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " The blob expiry was set successfully.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_sethttpheaders.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=properties&SetHTTPHeaders'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-blob-cache-control:{ x_ms_blob_cache_control }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-type:{ x_ms_blob_content_type }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-md5:{ x_ms_blob_content_md5 }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-encoding:{ x_ms_blob_content_encoding }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-language:{ x_ms_blob_content_language }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-disposition:{ x_ms_blob_content_dispositio }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " The properties were set successfully.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_setimmutabilitypolicy.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=immutabilityPolicies'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |x-ms-immutability-policy-until-date:{ x_ms_immutability_policy_unt }| TO lo_request->mt_headers.
    APPEND |x-ms-immutability-policy-mode:{ x_ms_immutability_policy_mod }| TO lo_request->mt_headers.
    IF snapshot IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |snapshot={ snapshot }|.
    ENDIF.
    IF versionid IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |versionid={ versionid }|.
    ENDIF.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " The immutability policy was successfully set.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_deleteimmutabilitypolic.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'DELETE'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=immutabilityPolicies'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    IF snapshot IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |snapshot={ snapshot }|.
    ENDIF.
    IF versionid IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |versionid={ versionid }|.
    ENDIF.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " The delete immutability policy request was accepted and the immutability policy will be deleted.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_setlegalhold.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=legalhold'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |x-ms-legal-hold:{ x_ms_legal_hold }| TO lo_request->mt_headers.
    IF snapshot IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |snapshot={ snapshot }|.
    ENDIF.
    IF versionid IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |versionid={ versionid }|.
    ENDIF.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " The legal hold was successfully set on the blob.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_setmetadata.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=metadata'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-meta:{ x_ms_meta }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key:{ x_ms_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key-sha256:{ x_ms_encryption_key_sha256 }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-algorithm:{ x_ms_encryption_algorithm }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-scope:{ x_ms_encryption_scope }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " The metadata was set successfully.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_acquirelease.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=lease&acquire'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    APPEND |x-ms-lease-action:{ x_ms_lease_action }| TO lo_request->mt_headers.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-duration:{ x_ms_lease_duration }| TO lo_request->mt_headers.
    APPEND |x-ms-proposed-lease-id:{ x_ms_proposed_lease_id }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 201. " The Acquire operation completed successfully.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_releaselease.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=lease&release'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    APPEND |x-ms-lease-action:{ x_ms_lease_action }| TO lo_request->mt_headers.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " The Release operation completed successfully.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_renewlease.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=lease&renew'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    APPEND |x-ms-lease-action:{ x_ms_lease_action }| TO lo_request->mt_headers.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " The Renew operation completed successfully.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_changelease.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=lease&change'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    APPEND |x-ms-lease-action:{ x_ms_lease_action }| TO lo_request->mt_headers.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-proposed-lease-id:{ x_ms_proposed_lease_id }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " The Change operation completed successfully.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_breaklease.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=lease&break'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    APPEND |x-ms-lease-action:{ x_ms_lease_action }| TO lo_request->mt_headers.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-break-period:{ x_ms_lease_break_period }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 202. " The Break operation completed successfully.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_createsnapshot.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=snapshot'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-meta:{ x_ms_meta }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key:{ x_ms_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key-sha256:{ x_ms_encryption_key_sha256 }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-algorithm:{ x_ms_encryption_algorithm }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-scope:{ x_ms_encryption_scope }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 201. " The snaptshot was taken successfully.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_startcopyfromurl.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=copy'.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-meta:{ x_ms_meta }| TO lo_request->mt_headers.
    APPEND |x-ms-access-tier:{ x_ms_access_tier }| TO lo_request->mt_headers.
    APPEND |x-ms-rehydrate-priority:{ x_ms_rehydrate_priority }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-modified-since:{ x_ms_source_if_modified_sinc }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-unmodified-since:{ x_ms_source_if_unmodified_si }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-match:{ x_ms_source_if_match }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-none-match:{ x_ms_source_if_none_match }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-tags:{ x_ms_source_if_tags }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-copy-source:{ x_ms_copy_source }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |x-ms-tags:{ x_ms_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-seal-blob:{ x_ms_seal_blob }| TO lo_request->mt_headers.
    APPEND |x-ms-immutability-policy-until-date:{ x_ms_immutability_policy_unt }| TO lo_request->mt_headers.
    APPEND |x-ms-immutability-policy-mode:{ x_ms_immutability_policy_mod }| TO lo_request->mt_headers.
    APPEND |x-ms-legal-hold:{ x_ms_legal_hold }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 202. " The copy blob has been accepted with the specified copy status.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_copyfromurl.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=copy&sync'.
    APPEND |x-ms-requires-sync:{ x_ms_requires_sync }| TO lo_request->mt_headers.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-meta:{ x_ms_meta }| TO lo_request->mt_headers.
    APPEND |x-ms-access-tier:{ x_ms_access_tier }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-modified-since:{ x_ms_source_if_modified_sinc }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-unmodified-since:{ x_ms_source_if_unmodified_si }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-match:{ x_ms_source_if_match }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-none-match:{ x_ms_source_if_none_match }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-copy-source:{ x_ms_copy_source }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |x-ms-source-content-md5:{ x_ms_source_content_md5 }| TO lo_request->mt_headers.
    APPEND |x-ms-tags:{ x_ms_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-immutability-policy-until-date:{ x_ms_immutability_policy_unt }| TO lo_request->mt_headers.
    APPEND |x-ms-immutability-policy-mode:{ x_ms_immutability_policy_mod }| TO lo_request->mt_headers.
    APPEND |x-ms-legal-hold:{ x_ms_legal_hold }| TO lo_request->mt_headers.
    APPEND |x-ms-copy-source-authorization:{ x_ms_copy_source_authorizati }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-scope:{ x_ms_encryption_scope }| TO lo_request->mt_headers.
    APPEND |x-ms-copy-source-tag-option:{ x_ms_copy_source_tag_option }| TO lo_request->mt_headers.
    APPEND |x-ms-file-request-intent:{ x_ms_file_request_intent }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 202. " The copy has completed.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_abortcopyfromurl.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=copy&copyid'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    APPEND |x-ms-copy-action:{ x_ms_copy_action }| TO lo_request->mt_headers.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF copyid IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |copyid={ copyid }|.
    ENDIF.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 204. " The delete request was accepted and the blob will be deleted.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_settier.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=tier'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF snapshot IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |snapshot={ snapshot }|.
    ENDIF.
    IF versionid IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |versionid={ versionid }|.
    ENDIF.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-access-tier:{ x_ms_access_tier }| TO lo_request->mt_headers.
    APPEND |x-ms-rehydrate-priority:{ x_ms_rehydrate_priority }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " The new tier will take effect immediately.
* todo, no content types
      WHEN 202. " The transition to the new tier is pending.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_getaccountinfo.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'GET'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?restype=account&comp=properties&blob'.
    IF restype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |restype={ restype }|.
    ENDIF.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Success (OK)
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blockblob_stageblock.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=block'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF blockid IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |blockid={ blockid }|.
    ENDIF.
    APPEND |Content-Length:{ content__length }| TO lo_request->mt_headers.
    APPEND |Content-MD5:{ content_md5 }| TO lo_request->mt_headers.
    APPEND |x-ms-content-crc64:{ x_ms_content_crc64 }| TO lo_request->mt_headers.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key:{ x_ms_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key-sha256:{ x_ms_encryption_key_sha256 }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-algorithm:{ x_ms_encryption_algorithm }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-scope:{ x_ms_encryption_scope }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |x-ms-structured-body:{ x_ms_structured_body }| TO lo_request->mt_headers.
    APPEND |x-ms-structured-content-length:{ x_ms_structured_content_leng }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    APPEND 'Content-Type:application/octet-stream' TO lo_request->mt_headers.
    lo_request->mv_body_bin = body.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 201. " The block was created.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blockblob_stageblockfromurl.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=block&fromURL'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF blockid IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |blockid={ blockid }|.
    ENDIF.
    APPEND |Content-Length:{ content__length }| TO lo_request->mt_headers.
    APPEND |x-ms-copy-source:{ x_ms_copy_source }| TO lo_request->mt_headers.
    APPEND |x-ms-source-range:{ x_ms_source_range }| TO lo_request->mt_headers.
    APPEND |x-ms-source-content-md5:{ x_ms_source_content_md5 }| TO lo_request->mt_headers.
    APPEND |x-ms-source-content-crc64:{ x_ms_source_content_crc64 }| TO lo_request->mt_headers.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-encryption-key:{ x_ms_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key-sha256:{ x_ms_encryption_key_sha256 }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-algorithm:{ x_ms_encryption_algorithm }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-scope:{ x_ms_encryption_scope }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-modified-since:{ x_ms_source_if_modified_sinc }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-unmodified-since:{ x_ms_source_if_unmodified_si }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-match:{ x_ms_source_if_match }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-none-match:{ x_ms_source_if_none_match }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |x-ms-copy-source-authorization:{ x_ms_copy_source_authorizati }| TO lo_request->mt_headers.
    APPEND |x-ms-file-request-intent:{ x_ms_file_request_intent }| TO lo_request->mt_headers.
    APPEND |x-ms-source-encryption-key:{ x_ms_source_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-source-encryption-key-sha256:{ x_ms_source_encryption_key_s }| TO lo_request->mt_headers.
    APPEND |x-ms-source-encryption-algorithm:{ x_ms_source_encryption_algor }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 201. " The block was created.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blockblob_commitblocklist.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=blocklist'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-blob-cache-control:{ x_ms_blob_cache_control }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-type:{ x_ms_blob_content_type }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-encoding:{ x_ms_blob_content_encoding }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-language:{ x_ms_blob_content_language }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-md5:{ x_ms_blob_content_md5 }| TO lo_request->mt_headers.
    APPEND |Content-MD5:{ content_md5 }| TO lo_request->mt_headers.
    APPEND |x-ms-content-crc64:{ x_ms_content_crc64 }| TO lo_request->mt_headers.
    APPEND |x-ms-meta:{ x_ms_meta }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-disposition:{ x_ms_blob_content_dispositio }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key:{ x_ms_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key-sha256:{ x_ms_encryption_key_sha256 }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-algorithm:{ x_ms_encryption_algorithm }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-scope:{ x_ms_encryption_scope }| TO lo_request->mt_headers.
    APPEND |x-ms-access-tier:{ x_ms_access_tier }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |x-ms-tags:{ x_ms_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-immutability-policy-until-date:{ x_ms_immutability_policy_unt }| TO lo_request->mt_headers.
    APPEND |x-ms-immutability-policy-mode:{ x_ms_immutability_policy_mod }| TO lo_request->mt_headers.
    APPEND |x-ms-legal-hold:{ x_ms_legal_hold }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    APPEND 'Content-Type:application/xml' TO lo_request->mt_headers.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 201. " The block list was recorded.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blockblob_getblocklist.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'GET'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=blocklist'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF snapshot IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |snapshot={ snapshot }|.
    ENDIF.
    IF blocklisttype IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |blocklisttype={ blocklisttype }|.
    ENDIF.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " The page range was written.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~pageblob_uploadpages.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=page&update'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    APPEND |x-ms-page-write:{ x_ms_page_write }| TO lo_request->mt_headers.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    APPEND |Content-Length:{ content__length }| TO lo_request->mt_headers.
    APPEND |Content-MD5:{ content_md5 }| TO lo_request->mt_headers.
    APPEND |x-ms-content-crc64:{ x_ms_content_crc64 }| TO lo_request->mt_headers.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-range:{ x_ms_range }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key:{ x_ms_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key-sha256:{ x_ms_encryption_key_sha256 }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-algorithm:{ x_ms_encryption_algorithm }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-scope:{ x_ms_encryption_scope }| TO lo_request->mt_headers.
    APPEND |x-ms-if-sequence-number-le:{ x_ms_if_sequence_number_le }| TO lo_request->mt_headers.
    APPEND |x-ms-if-sequence-number-lt:{ x_ms_if_sequence_number_lt }| TO lo_request->mt_headers.
    APPEND |x-ms-if-sequence-number-eq:{ x_ms_if_sequence_number_eq }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |x-ms-structured-body:{ x_ms_structured_body }| TO lo_request->mt_headers.
    APPEND |x-ms-structured-content-length:{ x_ms_structured_content_leng }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    APPEND 'Content-Type:application/octet-stream' TO lo_request->mt_headers.
    lo_request->mv_body_bin = body.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 201. " The page range was written.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~pageblob_clearpages.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=page&clear'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    APPEND |x-ms-page-write:{ x_ms_page_write }| TO lo_request->mt_headers.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    APPEND |Content-Length:{ content__length }| TO lo_request->mt_headers.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-range:{ x_ms_range }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key:{ x_ms_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key-sha256:{ x_ms_encryption_key_sha256 }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-algorithm:{ x_ms_encryption_algorithm }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-scope:{ x_ms_encryption_scope }| TO lo_request->mt_headers.
    APPEND |x-ms-if-sequence-number-le:{ x_ms_if_sequence_number_le }| TO lo_request->mt_headers.
    APPEND |x-ms-if-sequence-number-lt:{ x_ms_if_sequence_number_lt }| TO lo_request->mt_headers.
    APPEND |x-ms-if-sequence-number-eq:{ x_ms_if_sequence_number_eq }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 201. " The page range was cleared.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~pageblob_uploadpagesfromurl.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=page&update&fromUrl'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    APPEND |x-ms-page-write:{ x_ms_page_write }| TO lo_request->mt_headers.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    APPEND |x-ms-copy-source:{ x_ms_copy_source }| TO lo_request->mt_headers.
    APPEND |x-ms-source-range:{ x_ms_source_range }| TO lo_request->mt_headers.
    APPEND |x-ms-source-content-md5:{ x_ms_source_content_md5 }| TO lo_request->mt_headers.
    APPEND |x-ms-source-content-crc64:{ x_ms_source_content_crc64 }| TO lo_request->mt_headers.
    APPEND |Content-Length:{ content__length }| TO lo_request->mt_headers.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-range:{ x_ms_range }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key:{ x_ms_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key-sha256:{ x_ms_encryption_key_sha256 }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-algorithm:{ x_ms_encryption_algorithm }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-scope:{ x_ms_encryption_scope }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-if-sequence-number-le:{ x_ms_if_sequence_number_le }| TO lo_request->mt_headers.
    APPEND |x-ms-if-sequence-number-lt:{ x_ms_if_sequence_number_lt }| TO lo_request->mt_headers.
    APPEND |x-ms-if-sequence-number-eq:{ x_ms_if_sequence_number_eq }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-modified-since:{ x_ms_source_if_modified_sinc }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-unmodified-since:{ x_ms_source_if_unmodified_si }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-match:{ x_ms_source_if_match }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-none-match:{ x_ms_source_if_none_match }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |x-ms-copy-source-authorization:{ x_ms_copy_source_authorizati }| TO lo_request->mt_headers.
    APPEND |x-ms-file-request-intent:{ x_ms_file_request_intent }| TO lo_request->mt_headers.
    APPEND |x-ms-source-encryption-key:{ x_ms_source_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-source-encryption-key-sha256:{ x_ms_source_encryption_key_s }| TO lo_request->mt_headers.
    APPEND |x-ms-source-encryption-algorithm:{ x_ms_source_encryption_algor }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 201. " The page range was written.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~pageblob_getpageranges.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'GET'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=pagelist'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF snapshot IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |snapshot={ snapshot }|.
    ENDIF.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-range:{ x_ms_range }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    IF marker IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |marker={ marker }|.
    ENDIF.
    IF maxresults IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |maxresults={ maxresults }|.
    ENDIF.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Information on the page blob was found.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~pageblob_getpagerangesdiff.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'GET'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=pagelist&diff'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF snapshot IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |snapshot={ snapshot }|.
    ENDIF.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    IF prevsnapshot IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |prevsnapshot={ prevsnapshot }|.
    ENDIF.
    APPEND |x-ms-previous-snapshot-url:{ x_ms_previous_snapshot_url }| TO lo_request->mt_headers.
    APPEND |x-ms-range:{ x_ms_range }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    IF marker IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |marker={ marker }|.
    ENDIF.
    IF maxresults IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |maxresults={ maxresults }|.
    ENDIF.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Information on the page blob was found.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~pageblob_resize.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=properties&Resize'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key:{ x_ms_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key-sha256:{ x_ms_encryption_key_sha256 }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-algorithm:{ x_ms_encryption_algorithm }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-scope:{ x_ms_encryption_scope }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-content-length:{ x_ms_blob_content_length }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " The Blob was resized successfully
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~pageblob_updatesequencenumbe.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=properties&UpdateSequenceNumber'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-sequence-number-action:{ x_ms_sequence_number_action }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-sequence-number:{ x_ms_blob_sequence_number }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " The sequence numbers were updated successfully.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~pageblob_copyincremental.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=incrementalcopy'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-copy-source:{ x_ms_copy_source }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 202. " The blob was copied.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~appendblob_appendblock.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=appendblock'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |Content-Length:{ content__length }| TO lo_request->mt_headers.
    APPEND |Content-MD5:{ content_md5 }| TO lo_request->mt_headers.
    APPEND |x-ms-content-crc64:{ x_ms_content_crc64 }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-condition-maxsize:{ x_ms_blob_condition_maxsize }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-condition-appendpos:{ x_ms_blob_condition_appendpo }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key:{ x_ms_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key-sha256:{ x_ms_encryption_key_sha256 }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-algorithm:{ x_ms_encryption_algorithm }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-scope:{ x_ms_encryption_scope }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |x-ms-structured-body:{ x_ms_structured_body }| TO lo_request->mt_headers.
    APPEND |x-ms-structured-content-length:{ x_ms_structured_content_leng }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    APPEND 'Content-Type:application/octet-stream' TO lo_request->mt_headers.
    lo_request->mv_body_bin = body.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 201. " The block was created.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~appendblob_appendblockfromur.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=appendblock&fromUrl'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    APPEND |x-ms-copy-source:{ x_ms_copy_source }| TO lo_request->mt_headers.
    APPEND |x-ms-source-range:{ x_ms_source_range }| TO lo_request->mt_headers.
    APPEND |x-ms-source-content-md5:{ x_ms_source_content_md5 }| TO lo_request->mt_headers.
    APPEND |x-ms-source-content-crc64:{ x_ms_source_content_crc64 }| TO lo_request->mt_headers.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |Content-Length:{ content__length }| TO lo_request->mt_headers.
    APPEND |Content-MD5:{ content_md5 }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key:{ x_ms_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key-sha256:{ x_ms_encryption_key_sha256 }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-algorithm:{ x_ms_encryption_algorithm }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-scope:{ x_ms_encryption_scope }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-condition-maxsize:{ x_ms_blob_condition_maxsize }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-condition-appendpos:{ x_ms_blob_condition_appendpo }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-modified-since:{ x_ms_source_if_modified_sinc }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-unmodified-since:{ x_ms_source_if_unmodified_si }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-match:{ x_ms_source_if_match }| TO lo_request->mt_headers.
    APPEND |x-ms-source-if-none-match:{ x_ms_source_if_none_match }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |x-ms-copy-source-authorization:{ x_ms_copy_source_authorizati }| TO lo_request->mt_headers.
    APPEND |x-ms-file-request-intent:{ x_ms_file_request_intent }| TO lo_request->mt_headers.
    APPEND |x-ms-source-encryption-key:{ x_ms_source_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-source-encryption-key-sha256:{ x_ms_source_encryption_key_s }| TO lo_request->mt_headers.
    APPEND |x-ms-source-encryption-algorithm:{ x_ms_source_encryption_algor }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 201. " The block was created.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~appendblob_seal.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=seal'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-condition-appendpos:{ x_ms_blob_condition_appendpo }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " The blob was sealed.
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_query.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'POST'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=query'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF snapshot IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |snapshot={ snapshot }|.
    ENDIF.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key:{ x_ms_encryption_key }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-key-sha256:{ x_ms_encryption_key_sha256 }| TO lo_request->mt_headers.
    APPEND |x-ms-encryption-algorithm:{ x_ms_encryption_algorithm }| TO lo_request->mt_headers.
    APPEND |If-Modified-Since:{ if__modified__since }| TO lo_request->mt_headers.
    APPEND |If-Unmodified-Since:{ if__unmodified__since }| TO lo_request->mt_headers.
    APPEND |If-Match:{ if__match }| TO lo_request->mt_headers.
    APPEND |If-None-Match:{ if__none__match }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    APPEND 'Content-Type:application/xml' TO lo_request->mt_headers.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Returns the content of the entire blob.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* schema format:file (binary) -> raw bytes in return-raw_body_bin
            return-raw_body_bin = lo_response->get_body_bin( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
      WHEN 206. " Returns the content of a specified range of the blob.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* schema format:file (binary) -> raw bytes in return-raw_body_bin
            return-raw_body_bin = lo_response->get_body_bin( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_gettags.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'GET'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=tags'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    IF snapshot IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |snapshot={ snapshot }|.
    ENDIF.
    IF versionid IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |versionid={ versionid }|.
    ENDIF.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-if-modified-since:{ x_ms_blob_if_modified_since }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-if-unmodified-since:{ x_ms_blob_if_unmodified_sinc }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-if-match:{ x_ms_blob_if_match }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-if-none-match:{ x_ms_blob_if_none_match }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 200. " Retrieved blob tags
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.


  METHOD zif_az_blob_service~blob_settags.
    DATA lv_uri          TYPE string.
    DATA ls_header       LIKE LINE OF mt_extra_headers.
    DATA lv_dummy        TYPE string.
    DATA lv_content_type TYPE string.
    DATA lo_request  TYPE REF TO zcl_az_http_request.
    DATA lo_response TYPE REF TO zcl_az_http_response.
    lo_request = NEW zcl_az_http_request( ).

    TRY.
    lo_request->mv_method = 'PUT'.
    lv_uri = mv_uri_prefix && '/{containerName}/{blob}?comp=tags'.
    IF comp IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |comp={ comp }|.
    ENDIF.
    REPLACE FIRST OCCURRENCE OF '{containerName}' IN lv_uri WITH container_name.
    REPLACE FIRST OCCURRENCE OF '{blob}' IN lv_uri WITH blob.
    APPEND |x-ms-version:{ x_ms_version }| TO lo_request->mt_headers.
    IF timeout IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |timeout={ timeout }|.
    ENDIF.
    IF versionid IS NOT INITIAL.
      lv_uri = lv_uri && COND string( WHEN lv_uri CS '?' THEN '&' ELSE '?' )
                      && |versionid={ versionid }|.
    ENDIF.
    APPEND |Content-MD5:{ content_md5 }| TO lo_request->mt_headers.
    APPEND |x-ms-content-crc64:{ x_ms_content_crc64 }| TO lo_request->mt_headers.
    APPEND |x-ms-client-request-id:{ x_ms_client_request_id }| TO lo_request->mt_headers.
    APPEND |x-ms-if-tags:{ x_ms_if_tags }| TO lo_request->mt_headers.
    APPEND |x-ms-lease-id:{ x_ms_lease_id }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-if-modified-since:{ x_ms_blob_if_modified_since }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-if-unmodified-since:{ x_ms_blob_if_unmodified_sinc }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-if-match:{ x_ms_blob_if_match }| TO lo_request->mt_headers.
    APPEND |x-ms-blob-if-none-match:{ x_ms_blob_if_none_match }| TO lo_request->mt_headers.
    lo_request->mv_url = lv_uri.
    LOOP AT mt_extra_headers INTO ls_header.
      APPEND |{ ls_header-name }:{ ls_header-value }| TO lo_request->mt_headers.
    ENDLOOP.
    APPEND 'Content-Type:application/xml' TO lo_request->mt_headers.
    lo_response = mo_pipeline->send( lo_request ).

    " surface service-side failures as typed SDK exceptions (zcx_az_*)
    IF lo_response->is_success( ) <> abap_true.
      RAISE EXCEPTION TYPE zcx_az_service_error
        EXPORTING iv_message = lo_response->get_body( ).
    ENDIF.

    return-code     = lo_response->get_status_code( ).
    lv_content_type = lo_response->get_header( 'Content-Type' ).
    CASE return-code.
      WHEN 204. " The tags were applied to the blob
* todo, no content types
      WHEN OTHERS.
        SPLIT lv_content_type AT ';' INTO lv_content_type lv_dummy.
        CASE lv_content_type.
          WHEN 'application/xml'.
* content-type 'application/xml' (textual): raw payload in return-raw_body
            return-raw_body = lo_response->get_body( ).
          WHEN OTHERS.
* unexpected content type
        ENDCASE.
    ENDCASE.

      CATCH zcx_azure INTO DATA(lx_az_err).
        RAISE EXCEPTION lx_az_err.
      CATCH cx_root INTO DATA(lx_sdk_err).
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to process response: { lx_sdk_err->get_text( ) }|
            previous   = lx_sdk_err.
    ENDTRY.
  ENDMETHOD.

ENDCLASS.
