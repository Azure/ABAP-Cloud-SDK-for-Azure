*"* use this source file for your ABAP unit test classes

CLASS ltc_client_secret_cred DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    DATA mo_http TYPE REF TO zcl_az_http_client_mock.
    DATA mo_cut  TYPE REF TO zif_az_token_credential.

    METHODS setup.
    "! 200 + token JSON -> access token parsed and returned.
    METHODS returns_token_on_success    FOR TESTING RAISING zcx_azure.
    "! POSTs form-encoded client_credentials to the AAD v2 token endpoint.
    METHODS posts_to_token_endpoint     FOR TESTING RAISING zcx_azure.
    "! Non-2xx from the token endpoint -> zcx_az_auth_error.
    METHODS http_error_raises_auth_err  FOR TESTING.
    "! Empty body -> zcx_az_auth_error.
    METHODS empty_body_raises           FOR TESTING.
    "! JSON without access_token -> zcx_az_auth_error.
    METHODS missing_token_raises        FOR TESTING.
    "! Empty scope is rejected before any HTTP call is made.
    METHODS empty_scope_raises          FOR TESTING.
ENDCLASS.


CLASS ltc_client_secret_cred IMPLEMENTATION.

  METHOD setup.
    mo_http = NEW zcl_az_http_client_mock( ).
    mo_cut  = NEW zcl_az_client_secret_cred(
                iv_client_id     = 'CID'
                iv_client_secret = 'SECRET'
                iv_tenant_id     = 'TENANT'
                io_http_client   = mo_http ).
  ENDMETHOD.

  METHOD returns_token_on_success.
    mo_http->add_response(
      iv_status = 200
      iv_body   = `{"access_token":"abc123","token_type":"Bearer","expires_in":3599}` ).

    DATA(lo_token) = mo_cut->get_token( iv_scope = 'https://management.azure.com/.default' ).

    cl_abap_unit_assert=>assert_bound( lo_token ).
    cl_abap_unit_assert=>assert_equals( exp = 'abc123' act = lo_token->get_token( ) ).
  ENDMETHOD.

  METHOD posts_to_token_endpoint.
    mo_http->add_response(
      iv_status = 200
      iv_body   = `{"access_token":"t","token_type":"Bearer","expires_in":3599}` ).

    mo_cut->get_token( iv_scope = 'myscope/.default' ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'POST' act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_char_cp(
      exp = '*login.microsoftonline.com/TENANT/oauth2/v2.0/token*'
      act = lo_req->mv_url ).
    cl_abap_unit_assert=>assert_char_cp(
      exp = '*grant_type=client_credentials*client_id=CID*scope=myscope/.default*'
      act = lo_req->mv_body
      msg = 'form body not built correctly' ).
  ENDMETHOD.

  METHOD http_error_raises_auth_err.
    mo_http->add_response( iv_status = 401 iv_body = `{"error":"invalid_client"}` ).
    TRY.
        mo_cut->get_token( iv_scope = 'scope' ).
        cl_abap_unit_assert=>fail( 'expected zcx_az_auth_error' ).
      CATCH zcx_az_auth_error.
        " expected
    ENDTRY.
  ENDMETHOD.

  METHOD empty_body_raises.
    mo_http->add_response( iv_status = 200 ).         " 200 but no body
    TRY.
        mo_cut->get_token( iv_scope = 'scope' ).
        cl_abap_unit_assert=>fail( 'expected zcx_az_auth_error for empty body' ).
      CATCH zcx_az_auth_error.
        " expected
    ENDTRY.
  ENDMETHOD.

  METHOD missing_token_raises.
    mo_http->add_response(
      iv_status = 200
      iv_body   = `{"token_type":"Bearer","expires_in":3600}` ).
    TRY.
        mo_cut->get_token( iv_scope = 'scope' ).
        cl_abap_unit_assert=>fail( 'expected zcx_az_auth_error for missing access_token' ).
      CATCH zcx_az_auth_error.
        " expected
    ENDTRY.
  ENDMETHOD.

  METHOD empty_scope_raises.
    TRY.
        mo_cut->get_token( iv_scope = '' ).
        cl_abap_unit_assert=>fail( 'expected zcx_az_auth_error for empty scope' ).
      CATCH zcx_az_auth_error.
        " expected
    ENDTRY.
    cl_abap_unit_assert=>assert_equals(
      exp = 0 act = mo_http->get_call_count( )
      msg = 'no HTTP call should be made when scope is empty' ).
  ENDMETHOD.

ENDCLASS.
