*"* use this source file for your ABAP unit test classes
*"* use this source file for your ABAP unit test classes

" Captures the request handed downstream (to inspect the headers the
" shared-key policy produced).
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


CLASS ltc_policy_shared_key DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.

    CONSTANTS c_date TYPE string VALUE 'Fri, 01 Jan 2027 00:00:00 GMT'.
    " base64 for the bytes 'key' - any valid base64 works for signing tests
    CONSTANTS c_key  TYPE string VALUE 'a2V5'.

    "! Runs the shared-key policy over a request and returns the Authorization
    "! header the policy added (or '' if none).
    METHODS run_auth
      IMPORTING io_request     TYPE REF TO zcl_az_http_request
      RETURNING VALUE(rv_auth) TYPE string
      RAISING   zcx_az_http_error.

    " ---- canonicalization (pure) ----
    METHODS resource_without_query     FOR TESTING.
    METHODS resource_sorts_query       FOR TESTING.
    METHODS headers_sorted_x_ms_only   FOR TESTING.
    METHODS string_to_sign_layout      FOR TESTING.
    METHODS content_length_empty_get   FOR TESTING.
    METHODS content_length_from_body   FOR TESTING.

    " ---- process / signing ----
    METHODS adds_sharedkey_header      FOR TESTING RAISING zcx_az_http_error.
    METHODS signature_is_deterministic FOR TESTING RAISING zcx_az_http_error.
    METHODS missing_key_raises         FOR TESTING.

ENDCLASS.


CLASS ltc_policy_shared_key IMPLEMENTATION.

  METHOD run_auth.
    DATA(lo_capture) = NEW lcl_capture_policy( ).
    DATA(lo_ctx)     = NEW zcl_az_pipeline_context( VALUE #( ( lo_capture ) ) ).
    DATA(lo_cut)     = NEW zcl_az_policy_shared_key(
                         iv_account_name = 'acct'
                         iv_account_key  = c_key ).
    lo_cut->zif_az_http_pipeline_policy~process(
      io_request = io_request
      io_context = lo_ctx ).

    LOOP AT lo_capture->mo_seen->mt_headers INTO DATA(lv_h).
      IF lv_h CP 'Authorization: SharedKey *'.
        rv_auth = lv_h.
        RETURN.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

  METHOD resource_without_query.
    cl_abap_unit_assert=>assert_equals(
      exp = '/acct/cont/blob.txt'
      act = zcl_az_policy_shared_key=>canonicalized_resource(
              iv_account = 'acct'
              iv_url     = 'https://acct.blob.core.windows.net/cont/blob.txt' ) ).
  ENDMETHOD.

  METHOD resource_sorts_query.
    DATA(lv_lf) = cl_abap_char_utilities=>newline.
    " query params must be lower-cased and sorted: comp before restype
    cl_abap_unit_assert=>assert_equals(
      exp = |/acct/cont{ lv_lf }comp:list{ lv_lf }restype:container|
      act = zcl_az_policy_shared_key=>canonicalized_resource(
              iv_account = 'acct'
              iv_url     = 'https://acct.blob.core.windows.net/cont?restype=container&comp=list' ) ).
  ENDMETHOD.

  METHOD headers_sorted_x_ms_only.
    DATA(lv_lf) = cl_abap_char_utilities=>newline.
    DATA(lt) = VALUE zcl_az_http_request=>ty_t_headers(
      ( |x-ms-version:2023-11-03| )
      ( |Content-Type:text/plain| )
      ( |x-ms-date:{ c_date }| ) ).
    " only x-ms-* survive, sorted (date before version); Content-Type dropped
    cl_abap_unit_assert=>assert_equals(
      exp = |x-ms-date:{ c_date }{ lv_lf }x-ms-version:2023-11-03{ lv_lf }|
      act = zcl_az_policy_shared_key=>canonicalized_headers( lt ) ).
  ENDMETHOD.

  METHOD string_to_sign_layout.
    DATA(lv_lf) = cl_abap_char_utilities=>newline.
    DATA(lo_req) = NEW zcl_az_http_request( ).
    lo_req->mv_method  = 'GET'.
    lo_req->mv_url     = 'https://acct.blob.core.windows.net/cont?comp=list'.
    lo_req->mt_headers = VALUE #( ( |x-ms-date:{ c_date }| )
                                  ( |x-ms-version:2023-11-03| ) ).

    DATA(lv_exp) =
         |GET{ lv_lf }|     " verb
      && |{ lv_lf }|        " content-encoding
      && |{ lv_lf }|        " content-language
      && |{ lv_lf }|        " content-length (empty: no body)
      && |{ lv_lf }|        " content-md5
      && |{ lv_lf }|        " content-type
      && |{ lv_lf }|        " date (empty: x-ms-date used)
      && |{ lv_lf }|        " if-modified-since
      && |{ lv_lf }|        " if-match
      && |{ lv_lf }|        " if-none-match
      && |{ lv_lf }|        " if-unmodified-since
      && |{ lv_lf }|        " range
      && |x-ms-date:{ c_date }{ lv_lf }|
      && |x-ms-version:2023-11-03{ lv_lf }|
      && |/acct/cont{ lv_lf }comp:list|.

    cl_abap_unit_assert=>assert_equals(
      exp = lv_exp
      act = zcl_az_policy_shared_key=>build_string_to_sign(
              io_request = lo_req iv_account = 'acct' ) ).
  ENDMETHOD.

  METHOD content_length_empty_get.
    DATA(lv_lf) = cl_abap_char_utilities=>newline.
    DATA(lo_req) = NEW zcl_az_http_request( ).
    lo_req->mv_method = 'GET'.
    lo_req->mv_url    = 'https://acct.blob.core.windows.net/cont/b'.
    " a body-less request signs Content-Length as an empty field
    DATA(lv_sts) = zcl_az_policy_shared_key=>build_string_to_sign(
                     io_request = lo_req iv_account = 'acct' ).
    " the 4th line (Content-Length) must be empty
    SPLIT lv_sts AT lv_lf INTO TABLE DATA(lt_lines).
    cl_abap_unit_assert=>assert_equals( exp = '' act = lt_lines[ 4 ] ).
  ENDMETHOD.

  METHOD content_length_from_body.
    DATA(lv_lf) = cl_abap_char_utilities=>newline.
    DATA(lo_req) = NEW zcl_az_http_request( ).
    lo_req->mv_method   = 'PUT'.
    lo_req->mv_url      = 'https://acct.blob.core.windows.net/cont/b'.
    lo_req->mv_body_bin = '00112233'.            " 4 bytes
    DATA(lv_sts) = zcl_az_policy_shared_key=>build_string_to_sign(
                     io_request = lo_req iv_account = 'acct' ).
    SPLIT lv_sts AT lv_lf INTO TABLE DATA(lt_lines).
    cl_abap_unit_assert=>assert_equals( exp = '4' act = lt_lines[ 4 ] ).
  ENDMETHOD.

  METHOD adds_sharedkey_header.
    DATA(lo_req) = NEW zcl_az_http_request( ).
    lo_req->mv_method  = 'GET'.
    lo_req->mv_url     = 'https://acct.blob.core.windows.net/cont?comp=list'.
    lo_req->mt_headers = VALUE #( ( |x-ms-date:{ c_date }| )
                                  ( |x-ms-version:2023-11-03| ) ).

    DATA(lv_auth) = run_auth( lo_req ).

    cl_abap_unit_assert=>assert_char_cp(
      exp = 'Authorization: SharedKey acct:*'
      act = lv_auth ).
    " signature part must be present (non-empty base64 after the account)
    cl_abap_unit_assert=>assert_differs(
      exp = 'Authorization: SharedKey acct:'
      act = lv_auth
      msg = 'shared-key signature must not be empty' ).
  ENDMETHOD.

  METHOD signature_is_deterministic.
    " same canonical input (x-ms-date pre-set) => identical signature
    DATA(lo_a) = NEW zcl_az_http_request( ).
    lo_a->mv_method  = 'GET'.
    lo_a->mv_url     = 'https://acct.blob.core.windows.net/cont?comp=list'.
    lo_a->mt_headers = VALUE #( ( |x-ms-date:{ c_date }| ) ( |x-ms-version:2023-11-03| ) ).

    DATA(lo_b) = NEW zcl_az_http_request( ).
    lo_b->mv_method  = 'GET'.
    lo_b->mv_url     = 'https://acct.blob.core.windows.net/cont?comp=list'.
    lo_b->mt_headers = VALUE #( ( |x-ms-date:{ c_date }| ) ( |x-ms-version:2023-11-03| ) ).

    cl_abap_unit_assert=>assert_equals(
      exp = run_auth( lo_a )
      act = run_auth( lo_b ) ).
  ENDMETHOD.

  METHOD missing_key_raises.
    DATA(lo_capture) = NEW lcl_capture_policy( ).
    DATA(lo_ctx)     = NEW zcl_az_pipeline_context( VALUE #( ( lo_capture ) ) ).
    DATA(lo_cut)     = NEW zcl_az_policy_shared_key(
                         iv_account_name = 'acct'
                         iv_account_key  = '' ).
    DATA(lo_req) = NEW zcl_az_http_request( ).
    lo_req->mv_url = 'https://acct.blob.core.windows.net/cont'.

    TRY.
        lo_cut->zif_az_http_pipeline_policy~process(
          io_request = lo_req io_context = lo_ctx ).
        cl_abap_unit_assert=>fail( 'expected zcx_az_http_error for empty key' ).
      CATCH zcx_az_http_error.
        " expected
    ENDTRY.
  ENDMETHOD.

ENDCLASS.
