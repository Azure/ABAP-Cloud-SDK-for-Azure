*"* use this source file for your ABAP unit test classes

CLASS ltc_http_response DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    METHODS textual_content_types       FOR TESTING.
    METHODS binary_content_types        FOR TESTING.
    METHODS is_success_2xx_only         FOR TESTING.
    METHODS get_header_case_insensitive FOR TESTING.
    METHODS get_header_not_found        FOR TESTING.
    METHODS body_accessors              FOR TESTING.
ENDCLASS.


CLASS ltc_http_response IMPLEMENTATION.

  METHOD textual_content_types.
    cl_abap_unit_assert=>assert_equals( exp = abap_true
      act = zcl_az_http_response=>is_textual_content_type( 'application/json' ) ).
    cl_abap_unit_assert=>assert_equals( exp = abap_true
      act = zcl_az_http_response=>is_textual_content_type( 'application/json; charset=utf-8' ) ).
    cl_abap_unit_assert=>assert_equals( exp = abap_true
      act = zcl_az_http_response=>is_textual_content_type( 'application/xml' ) ).
    cl_abap_unit_assert=>assert_equals( exp = abap_true
      act = zcl_az_http_response=>is_textual_content_type( 'text/plain' ) ).
    cl_abap_unit_assert=>assert_equals( exp = abap_true
      act = zcl_az_http_response=>is_textual_content_type( '' ) ).
  ENDMETHOD.

  METHOD binary_content_types.
    cl_abap_unit_assert=>assert_equals( exp = abap_false
      act = zcl_az_http_response=>is_textual_content_type( 'application/octet-stream' ) ).
    cl_abap_unit_assert=>assert_equals( exp = abap_false
      act = zcl_az_http_response=>is_textual_content_type( 'image/png' ) ).
    cl_abap_unit_assert=>assert_equals( exp = abap_false
      act = zcl_az_http_response=>is_textual_content_type( 'application/zip' ) ).
  ENDMETHOD.

  METHOD is_success_2xx_only.
    cl_abap_unit_assert=>assert_equals( exp = abap_true
      act = NEW zcl_az_http_response( iv_status_code = 200 )->is_success( ) ).
    cl_abap_unit_assert=>assert_equals( exp = abap_true
      act = NEW zcl_az_http_response( iv_status_code = 202 )->is_success( ) ).
    cl_abap_unit_assert=>assert_equals( exp = abap_true
      act = NEW zcl_az_http_response( iv_status_code = 204 )->is_success( ) ).
    cl_abap_unit_assert=>assert_equals( exp = abap_false
      act = NEW zcl_az_http_response( iv_status_code = 199 )->is_success( ) ).
    cl_abap_unit_assert=>assert_equals( exp = abap_false
      act = NEW zcl_az_http_response( iv_status_code = 300 )->is_success( ) ).
    cl_abap_unit_assert=>assert_equals( exp = abap_false
      act = NEW zcl_az_http_response( iv_status_code = 404 )->is_success( ) ).
    cl_abap_unit_assert=>assert_equals( exp = abap_false
      act = NEW zcl_az_http_response( iv_status_code = 500 )->is_success( ) ).
  ENDMETHOD.

  METHOD get_header_case_insensitive.
    " regression guard for the transport header-propagation fix: the generated
    " client's Content-Type dispatch relies on case-insensitive get_header.
    DATA(lo) = NEW zcl_az_http_response(
      iv_status_code = 200
      it_headers = VALUE #( ( `Content-Type:application/json; charset=utf-8` )
                            ( `x-ms-request-id:abc-123` ) ) ).
    cl_abap_unit_assert=>assert_equals(
      exp = 'application/json; charset=utf-8' act = lo->get_header( 'content-type' ) ).
    cl_abap_unit_assert=>assert_equals(
      exp = 'abc-123' act = lo->get_header( 'X-MS-Request-Id' ) ).
  ENDMETHOD.

  METHOD get_header_not_found.
    DATA(lo) = NEW zcl_az_http_response(
      iv_status_code = 200
      it_headers = VALUE #( ( `content-type:application/json` ) ) ).
    cl_abap_unit_assert=>assert_initial( lo->get_header( 'ETag' ) ).
  ENDMETHOD.

  METHOD body_accessors.
    DATA lv_bin TYPE xstring VALUE '4869'.
    cl_abap_unit_assert=>assert_equals( exp = 'hello'
      act = NEW zcl_az_http_response( iv_status_code = 200 iv_body = `hello` )->get_body( ) ).
    cl_abap_unit_assert=>assert_equals( exp = lv_bin
      act = NEW zcl_az_http_response( iv_status_code = 200 iv_body_bin = lv_bin )->get_body_bin( ) ).
    cl_abap_unit_assert=>assert_equals( exp = 204
      act = NEW zcl_az_http_response( iv_status_code = 204 )->get_status_code( ) ).
  ENDMETHOD.

ENDCLASS.
