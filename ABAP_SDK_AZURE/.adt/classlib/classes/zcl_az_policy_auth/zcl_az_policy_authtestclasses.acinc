*"* use this source file for your ABAP unit test classes

" Captures the request it is handed (to assert the bearer header).
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

" Always fails downstream (to prove auth re-raises rather than swallows).
CLASS lcl_throw_policy DEFINITION.
  PUBLIC SECTION.
    INTERFACES zif_az_http_pipeline_policy.
ENDCLASS.
CLASS lcl_throw_policy IMPLEMENTATION.
  METHOD zif_az_http_pipeline_policy~process.
    RAISE EXCEPTION TYPE zcx_az_http_error EXPORTING iv_status_code = 503.
  ENDMETHOD.
ENDCLASS.


CLASS ltc_policy_auth DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    METHODS attaches_bearer_and_scope FOR TESTING RAISING zcx_azure.
    METHODS downstream_error_reraised FOR TESTING.
    METHODS token_failure_propagates  FOR TESTING.
ENDCLASS.


CLASS ltc_policy_auth IMPLEMENTATION.

  METHOD attaches_bearer_and_scope.
    DATA(lo_cap)  = NEW lcl_capture_policy( ).
    DATA(lo_ctx)  = NEW zcl_az_pipeline_context( VALUE #( ( lo_cap ) ) ).
    DATA(lo_cred) = NEW zcl_az_token_credential_fake( ).
    DATA(lo_auth) = NEW zcl_az_policy_auth(
                      io_credential = lo_cred
                      iv_scope      = 'https://management.azure.com/.default' ).

    lo_auth->zif_az_http_pipeline_policy~process(
      io_request = NEW zcl_az_http_request( )
      io_context = lo_ctx ).

    READ TABLE lo_cap->mo_seen->mt_headers
      WITH KEY table_line = 'Authorization: Bearer FAKE.JWT.TOKEN'
      TRANSPORTING NO FIELDS.
    cl_abap_unit_assert=>assert_subrc( msg = 'bearer token header not attached' ).
    cl_abap_unit_assert=>assert_equals(
      exp = 'https://management.azure.com/.default'
      act = lo_cred->get_scope_seen( ) ).
  ENDMETHOD.

  METHOD downstream_error_reraised.
    DATA(lo_ctx)  = NEW zcl_az_pipeline_context( VALUE #( ( NEW lcl_throw_policy( ) ) ) ).
    DATA(lo_auth) = NEW zcl_az_policy_auth(
                      io_credential = NEW zcl_az_token_credential_fake( )
                      iv_scope      = 'scope' ).
    TRY.
        lo_auth->zif_az_http_pipeline_policy~process(
          io_request = NEW zcl_az_http_request( )
          io_context = lo_ctx ).
        cl_abap_unit_assert=>fail( 'auth policy swallowed the downstream error' ).
      CATCH zcx_az_http_error.
        " expected: the real error must surface
    ENDTRY.
  ENDMETHOD.

  METHOD token_failure_propagates.
    DATA(lo_ctx)  = NEW zcl_az_pipeline_context( VALUE #( ( NEW lcl_capture_policy( ) ) ) ).
    DATA(lo_auth) = NEW zcl_az_policy_auth(
                      io_credential = NEW zcl_az_token_credential_fake( iv_fail = abap_true )
                      iv_scope      = 'scope' ).
    TRY.
        lo_auth->zif_az_http_pipeline_policy~process(
          io_request = NEW zcl_az_http_request( )
          io_context = lo_ctx ).
        cl_abap_unit_assert=>fail( 'token failure was not surfaced' ).
      CATCH zcx_az_http_error.
        " expected: auth wraps the credential failure
    ENDTRY.
  ENDMETHOD.

ENDCLASS.
