*"* use this source file for your ABAP unit test classes

" Transport-level tests. The real HTTP execution (cl_web_http_client_manager /
" if_web_http_*) cannot be cheaply stubbed (kernel interfaces, 70+ methods, and
" if_web_http_request has no system source), so the two behaviours that the fixes
" introduced are extracted into pure helper methods and tested directly here:
"   - needs_zero_length_body  -> the Content-Length:0 / HTTP 411 decision
"   - to_header_lines         -> the response-header propagation
CLASS ltc_http_client DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    METHODS req
      IMPORTING iv_method     TYPE string
                iv_body       TYPE string  OPTIONAL
                iv_body_bin   TYPE xstring OPTIONAL
      RETURNING VALUE(ro_req) TYPE REF TO zcl_az_http_request.

    METHODS post_no_body_needs_length   FOR TESTING.
    METHODS put_no_body_needs_length    FOR TESTING.
    METHODS post_with_text_body_no_len  FOR TESTING.
    METHODS post_with_bin_body_no_len   FOR TESTING.
    METHODS get_never_needs_length      FOR TESTING.
    METHODS delete_never_needs_length   FOR TESTING.
    METHODS headers_are_propagated      FOR TESTING.
    METHODS empty_headers_yield_empty   FOR TESTING.
ENDCLASS.


CLASS ltc_http_client IMPLEMENTATION.

  METHOD req.
    ro_req = NEW zcl_az_http_request( ).
    ro_req->mv_method   = iv_method.
    ro_req->mv_body     = iv_body.
    ro_req->mv_body_bin = iv_body_bin.
  ENDMETHOD.

  METHOD post_no_body_needs_length.
    cl_abap_unit_assert=>assert_equals( exp = abap_true
      act = zcl_az_http_client=>needs_zero_length_body( req( 'POST' ) ) ).
  ENDMETHOD.

  METHOD put_no_body_needs_length.
    cl_abap_unit_assert=>assert_equals( exp = abap_true
      act = zcl_az_http_client=>needs_zero_length_body( req( 'PUT' ) ) ).
  ENDMETHOD.

  METHOD post_with_text_body_no_len.
    cl_abap_unit_assert=>assert_equals( exp = abap_false
      act = zcl_az_http_client=>needs_zero_length_body( req( iv_method = 'POST' iv_body = '{}' ) ) ).
  ENDMETHOD.

  METHOD post_with_bin_body_no_len.
    cl_abap_unit_assert=>assert_equals( exp = abap_false
      act = zcl_az_http_client=>needs_zero_length_body( req( iv_method = 'POST' iv_body_bin = '00' ) ) ).
  ENDMETHOD.

  METHOD get_never_needs_length.
    cl_abap_unit_assert=>assert_equals( exp = abap_false
      act = zcl_az_http_client=>needs_zero_length_body( req( 'GET' ) ) ).
  ENDMETHOD.

  METHOD delete_never_needs_length.
    cl_abap_unit_assert=>assert_equals( exp = abap_false
      act = zcl_az_http_client=>needs_zero_length_body( req( 'DELETE' ) ) ).
  ENDMETHOD.

  METHOD headers_are_propagated.
    DATA(lt) = zcl_az_http_client=>to_header_lines(
      VALUE #( ( name = 'Content-Type'    value = 'application/json; charset=utf-8' )
               ( name = 'x-ms-request-id' value = 'abc-123' ) ) ).
    cl_abap_unit_assert=>assert_equals( exp = 2 act = lines( lt ) ).
    " Compare the produced 'name:value' lines directly. String literals
    " (backticks) keep the expected values typed as string, matching the
    " table's line type exactly.
    cl_abap_unit_assert=>assert_equals(
      exp = `Content-Type:application/json; charset=utf-8` act = lt[ 1 ] ).
    cl_abap_unit_assert=>assert_equals(
      exp = `x-ms-request-id:abc-123` act = lt[ 2 ] ).
  ENDMETHOD.

  METHOD empty_headers_yield_empty.
    cl_abap_unit_assert=>assert_initial(
      zcl_az_http_client=>to_header_lines( VALUE #( ) ) ).
  ENDMETHOD.

ENDCLASS.
