*"* use this source file for your ABAP unit test classes

" Scriptable downstream policy: returns a status per call, or raises.
CLASS lcl_seq_policy DEFINITION.
  PUBLIC SECTION.
    INTERFACES zif_az_http_pipeline_policy.
    DATA mt_status TYPE STANDARD TABLE OF i WITH EMPTY KEY.
    DATA mv_raise  TYPE abap_bool.
    DATA mv_calls  TYPE i.
ENDCLASS.
CLASS lcl_seq_policy IMPLEMENTATION.
  METHOD zif_az_http_pipeline_policy~process.
    mv_calls = mv_calls + 1.
    IF mv_raise = abap_true.
      RAISE EXCEPTION TYPE zcx_az_http_error EXPORTING iv_status_code = 0.
    ENDIF.
    DATA(lv_idx) = COND i( WHEN mv_calls <= lines( mt_status )
                           THEN mv_calls ELSE lines( mt_status ) ).
    DATA(lv_status) = COND i( WHEN lv_idx = 0 THEN 200 ELSE mt_status[ lv_idx ] ).
    ro_response = NEW zcl_az_http_response( iv_status_code = lv_status ).
  ENDMETHOD.
ENDCLASS.


CLASS ltc_policy_retry DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    METHODS run
      IMPORTING io_seq             TYPE REF TO lcl_seq_policy
      RETURNING VALUE(ro_response) TYPE REF TO zcl_az_http_response
      RAISING   zcx_az_http_error.
    METHODS succeeds_first_try    FOR TESTING RAISING zcx_azure.
    METHODS retries_then_succeeds FOR TESTING RAISING zcx_azure.
    METHODS exhausts_on_5xx       FOR TESTING.
    METHODS exhausts_on_exception FOR TESTING.
ENDCLASS.


CLASS ltc_policy_retry IMPLEMENTATION.

  METHOD run.
    DATA(lo_ctx)   = NEW zcl_az_pipeline_context( VALUE #( ( io_seq ) ) ).
    DATA(lo_retry) = NEW zcl_az_policy_retry( iv_max_retries = 3 ).
    ro_response = lo_retry->zif_az_http_pipeline_policy~process(
                    io_request = NEW zcl_az_http_request( )
                    io_context = lo_ctx ).
  ENDMETHOD.

  METHOD succeeds_first_try.
    DATA(lo_seq) = NEW lcl_seq_policy( ).
    lo_seq->mt_status = VALUE #( ( 200 ) ).
    DATA(lo_resp) = run( lo_seq ).
    cl_abap_unit_assert=>assert_equals( exp = 200 act = lo_resp->get_status_code( ) ).
    cl_abap_unit_assert=>assert_equals( exp = 1   act = lo_seq->mv_calls ).
  ENDMETHOD.

  METHOD retries_then_succeeds.
    DATA(lo_seq) = NEW lcl_seq_policy( ).
    lo_seq->mt_status = VALUE #( ( 503 ) ( 200 ) ).
    DATA(lo_resp) = run( lo_seq ).
    cl_abap_unit_assert=>assert_equals( exp = 200 act = lo_resp->get_status_code( ) ).
    cl_abap_unit_assert=>assert_equals( exp = 2   act = lo_seq->mv_calls
      msg = 'retry did not re-issue the request' ).
  ENDMETHOD.

  METHOD exhausts_on_5xx.
    DATA(lo_seq) = NEW lcl_seq_policy( ).
    lo_seq->mt_status = VALUE #( ( 500 ) ).
    TRY.
        run( lo_seq ).
        cl_abap_unit_assert=>fail( 'expected exhaustion exception' ).
      CATCH zcx_az_http_error.
        cl_abap_unit_assert=>assert_equals( exp = 3 act = lo_seq->mv_calls ).
    ENDTRY.
  ENDMETHOD.

  METHOD exhausts_on_exception.
    DATA(lo_seq) = NEW lcl_seq_policy( ).
    lo_seq->mv_raise = abap_true.
    TRY.
        run( lo_seq ).
        cl_abap_unit_assert=>fail( 'expected exhaustion exception' ).
      CATCH zcx_az_http_error.
        cl_abap_unit_assert=>assert_equals( exp = 3 act = lo_seq->mv_calls ).
    ENDTRY.
  ENDMETHOD.

ENDCLASS.
