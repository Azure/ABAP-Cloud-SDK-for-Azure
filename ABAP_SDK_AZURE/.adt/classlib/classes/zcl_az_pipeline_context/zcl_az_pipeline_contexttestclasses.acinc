*"* use this source file for your ABAP unit test classes

" Counts how often it is executed, so tests can prove the context re-runs it.
CLASS lcl_count_policy DEFINITION.
  PUBLIC SECTION.
    INTERFACES zif_az_http_pipeline_policy.
    DATA mv_calls TYPE i.
ENDCLASS.
CLASS lcl_count_policy IMPLEMENTATION.
  METHOD zif_az_http_pipeline_policy~process.
    mv_calls = mv_calls + 1.
    ro_response = NEW zcl_az_http_response( iv_status_code = 200 ).
  ENDMETHOD.
ENDCLASS.


CLASS ltc_pipeline_context DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    METHODS next_runs_first_policy        FOR TESTING RAISING zcx_azure.
    METHODS next_repeatable_immutable     FOR TESTING RAISING zcx_azure.
    METHODS next_past_end_returns_unbound FOR TESTING RAISING zcx_azure.
ENDCLASS.


CLASS ltc_pipeline_context IMPLEMENTATION.

  METHOD next_runs_first_policy.
    DATA(lo_p)   = NEW lcl_count_policy( ).
    DATA(lo_ctx) = NEW zcl_az_pipeline_context( VALUE #( ( lo_p ) ) ).
    DATA(lo_resp) = lo_ctx->next( NEW zcl_az_http_request( ) ).
    cl_abap_unit_assert=>assert_bound( lo_resp ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = lo_p->mv_calls ).
  ENDMETHOD.

  METHOD next_repeatable_immutable.
    " The SAME context invoked twice must re-run the downstream each time.
    " Regression guard for the retry-masking bug (old shared forward-only index).
    DATA(lo_p)   = NEW lcl_count_policy( ).
    DATA(lo_ctx) = NEW zcl_az_pipeline_context( VALUE #( ( lo_p ) ) ).
    DATA(lo_req) = NEW zcl_az_http_request( ).
    DATA(r1) = lo_ctx->next( lo_req ).
    DATA(r2) = lo_ctx->next( lo_req ).
    cl_abap_unit_assert=>assert_bound( r1 ).
    cl_abap_unit_assert=>assert_bound( r2 ).
    cl_abap_unit_assert=>assert_equals( exp = 2 act = lo_p->mv_calls
      msg = 'context did not re-run downstream on the 2nd call' ).
  ENDMETHOD.

  METHOD next_past_end_returns_unbound.
    DATA(lo_p)   = NEW lcl_count_policy( ).
    DATA(lo_ctx) = NEW zcl_az_pipeline_context(
      tt_policies = VALUE #( ( lo_p ) )
      iv_index    = 2 ).                  " only 1 policy -> index 2 is past the end
    DATA(lo_resp) = lo_ctx->next( NEW zcl_az_http_request( ) ).
    cl_abap_unit_assert=>assert_initial( lo_resp ).
    cl_abap_unit_assert=>assert_equals( exp = 0 act = lo_p->mv_calls ).
  ENDMETHOD.

ENDCLASS.
