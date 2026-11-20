*"* use this source file for your ABAP unit test classes
*"* use this source file for your ABAP unit test classes

" Captures the request it is handed (to assert the URL the SAS policy produced).
CLASS lcl_capture_policy DEFINITION.
  PUBLIC SECTION.
    INTERFACES zif_az_http_pipeline_policy.
    DATA mo_seen TYPE REF TO zcl_az_http_request.
ENDCLASS.
CLASS lcl_capture_policy IMPLEMENTATION.
  METHOD zif_az_http_pipeline_policy~process.
    mo_seen = io_request.
    ro_response = NEW zcl_az_http_response( iv_status_code = 200 ).
  ENDMETHOD.
ENDCLASS.


CLASS ltc_policy_sas DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    "! Runs the SAS policy over a request with the given URL, returns the
    "! URL seen downstream.
    METHODS run
      IMPORTING iv_sas        TYPE string
                iv_url        TYPE string
      RETURNING VALUE(rv_url) TYPE string
      RAISING   zcx_az_http_error.

    METHODS appends_sas_when_no_query  FOR TESTING RAISING zcx_az_http_error.
    METHODS appends_sas_with_ampersand FOR TESTING RAISING zcx_az_http_error.
    METHODS strips_leading_question    FOR TESTING RAISING zcx_az_http_error.
    METHODS empty_sas_leaves_url       FOR TESTING RAISING zcx_az_http_error.
    METHODS no_authorization_header    FOR TESTING RAISING zcx_az_http_error.
ENDCLASS.


CLASS ltc_policy_sas IMPLEMENTATION.

  METHOD run.
    DATA(lo_capture) = NEW lcl_capture_policy( ).
    DATA(lo_ctx)     = NEW zcl_az_pipeline_context( VALUE #( ( lo_capture ) ) ).
    DATA(lo_sas)     = NEW zcl_az_policy_sas( iv_sas ).
    DATA(lo_req)     = NEW zcl_az_http_request( ).
    lo_req->mv_url = iv_url.
    lo_sas->zif_az_http_pipeline_policy~process(
      io_request = lo_req
      io_context = lo_ctx ).
    rv_url = lo_capture->mo_seen->mv_url.
  ENDMETHOD.

  METHOD appends_sas_when_no_query.
    cl_abap_unit_assert=>assert_equals(
      exp = 'https://a.blob.core.windows.net/c/b?sv=2023-11-03&sig=abc'
      act = run( iv_sas = 'sv=2023-11-03&sig=abc'
                 iv_url = 'https://a.blob.core.windows.net/c/b' ) ).
  ENDMETHOD.

  METHOD appends_sas_with_ampersand.
    cl_abap_unit_assert=>assert_equals(
      exp = 'https://a.blob.core.windows.net/c?comp=list&sv=1&sig=x'
      act = run( iv_sas = 'sv=1&sig=x'
                 iv_url = 'https://a.blob.core.windows.net/c?comp=list' ) ).
  ENDMETHOD.

  METHOD strips_leading_question.
    " a SAS passed with a leading '?' must not produce '??'
    cl_abap_unit_assert=>assert_equals(
      exp = 'https://a.blob.core.windows.net/c/b?sv=1&sig=x'
      act = run( iv_sas = '?sv=1&sig=x'
                 iv_url = 'https://a.blob.core.windows.net/c/b' ) ).
  ENDMETHOD.

  METHOD empty_sas_leaves_url.
    cl_abap_unit_assert=>assert_equals(
      exp = 'https://a.blob.core.windows.net/c/b'
      act = run( iv_sas = ''
                 iv_url = 'https://a.blob.core.windows.net/c/b' ) ).
  ENDMETHOD.

  METHOD no_authorization_header.
    DATA(lo_capture) = NEW lcl_capture_policy( ).
    DATA(lo_ctx)     = NEW zcl_az_pipeline_context( VALUE #( ( lo_capture ) ) ).
    DATA(lo_sas)     = NEW zcl_az_policy_sas( 'sv=1&sig=x' ).
    DATA(lo_req)     = NEW zcl_az_http_request( ).
    lo_req->mv_url = 'https://a.blob.core.windows.net/c/b'.
    lo_sas->zif_az_http_pipeline_policy~process(
      io_request = lo_req io_context = lo_ctx ).
    " SAS auth must NOT add an Authorization header
    READ TABLE lo_capture->mo_seen->mt_headers
      TRANSPORTING NO FIELDS WITH KEY table_line = 'Authorization: Bearer'.
    cl_abap_unit_assert=>assert_subrc( exp = 4 msg = 'SAS must not add Authorization header' ).
  ENDMETHOD.

ENDCLASS.
