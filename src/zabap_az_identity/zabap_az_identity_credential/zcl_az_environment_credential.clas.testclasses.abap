*"* use this source file for your ABAP unit test classes

CLASS ltc_environment_credential DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    CLASS-DATA go_osql TYPE REF TO if_osql_test_environment.
    CLASS-METHODS class_setup.
    CLASS-METHODS class_teardown.

    DATA mo_http TYPE REF TO zcl_az_http_client_mock.
    DATA mo_cut  TYPE REF TO zif_az_token_credential.

    METHODS setup.
    METHODS seed
      IMPORTING iv_name  TYPE string
                iv_value TYPE string.

    "! Reads AZURE_* config, builds a client-secret cred and delegates; config
    "! values flow into the AAD token request.
    METHODS delegates_with_full_config FOR TESTING RAISING zcx_azure.
    "! Missing config (no AZURE_CLIENT_ID) -> zcx_az_auth_error, no HTTP call.
    METHODS missing_config_raises      FOR TESTING.
    "! Empty scope is rejected up front.
    METHODS empty_scope_raises         FOR TESTING.
ENDCLASS.


CLASS ltc_environment_credential IMPLEMENTATION.

  METHOD class_setup.
    " mock the zaz_config DB table so the SELECT in get_env_value is deterministic
    go_osql = cl_osql_test_environment=>create( VALUE #( ( 'ZAZ_CONFIG' ) ) ).
  ENDMETHOD.

  METHOD class_teardown.
    go_osql->destroy( ).
  ENDMETHOD.

  METHOD setup.
    go_osql->clear_doubles( ).
    mo_http = NEW zcl_az_http_client_mock( ).
    mo_cut  = NEW zcl_az_environment_credential( io_http_client = mo_http ).
  ENDMETHOD.

  METHOD seed.
    DATA lt_cfg TYPE STANDARD TABLE OF zaz_config.
    lt_cfg = VALUE #( ( client = sy-mandt name = iv_name value = iv_value ) ).
    go_osql->insert_test_data( lt_cfg ).
  ENDMETHOD.

  METHOD delegates_with_full_config.
    seed( iv_name = 'AZURE_CLIENT_ID'     iv_value = 'CID' ).
    seed( iv_name = 'AZURE_CLIENT_SECRET' iv_value = 'SEC' ).
    seed( iv_name = 'AZURE_TENANT_ID'     iv_value = 'TEN' ).

    mo_http->add_response(
      iv_status = 200
      iv_body   = `{"access_token":"env-tok","token_type":"Bearer","expires_in":3599}` ).

    DATA(lo_token) = mo_cut->get_token( iv_scope = 'scope/.default' ).

    cl_abap_unit_assert=>assert_equals( exp = 'env-tok' act = lo_token->get_token( ) ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_char_cp(
      exp = '*login.microsoftonline.com/TEN/oauth2/v2.0/token*' act = lo_req->mv_url ).
    cl_abap_unit_assert=>assert_char_cp(
      exp = '*client_id=CID*client_secret=SEC*' act = lo_req->mv_body
      msg = 'config values did not flow into the token request' ).
  ENDMETHOD.

  METHOD missing_config_raises.
    " seed nothing -> AZURE_CLIENT_ID is empty
    TRY.
        mo_cut->get_token( iv_scope = 'scope' ).
        cl_abap_unit_assert=>fail( 'expected zcx_az_auth_error for missing config' ).
      CATCH zcx_az_auth_error.
        " expected
    ENDTRY.
    cl_abap_unit_assert=>assert_equals( exp = 0 act = mo_http->get_call_count( ) ).
  ENDMETHOD.

  METHOD empty_scope_raises.
    TRY.
        mo_cut->get_token( iv_scope = '' ).
        cl_abap_unit_assert=>fail( 'expected zcx_az_auth_error for empty scope' ).
      CATCH zcx_az_auth_error.
        " expected
    ENDTRY.
  ENDMETHOD.

ENDCLASS.
