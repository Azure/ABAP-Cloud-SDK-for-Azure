*"* use this source file for your ABAP unit test classes

CLASS ltc_default_credential DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    "! First credential that yields a token wins; later ones are not tried.
    METHODS first_success_wins    FOR TESTING RAISING zcx_azure.
    "! A failing credential is skipped and the next one is tried.
    METHODS falls_back_on_failure FOR TESTING RAISING zcx_azure.
    "! All credentials failing -> zcx_az_auth_error.
    METHODS all_fail_raises       FOR TESTING RAISING zcx_azure.
    "! Empty chain -> zcx_az_auth_error.
    METHODS empty_chain_raises    FOR TESTING RAISING zcx_azure.
    "! Empty scope is rejected up front.
    METHODS empty_scope_raises    FOR TESTING RAISING zcx_azure.
ENDCLASS.


CLASS ltc_default_credential IMPLEMENTATION.

  METHOD first_success_wins.
    DATA(lo_chain)  = NEW zcl_az_default_credential( iv_register_defaults = abap_false ).
    DATA(lo_first)  = NEW zcl_az_token_credential_fake( iv_token = 'T1' ).
    DATA(lo_second) = NEW zcl_az_token_credential_fake( iv_token = 'T2' ).
    lo_chain->add_credential( lo_first ).
    lo_chain->add_credential( lo_second ).

    DATA(lo_token) = lo_chain->zif_az_token_credential~get_token( iv_scope = 'scope' ).

    cl_abap_unit_assert=>assert_equals( exp = 'T1' act = lo_token->get_token( ) ).
    cl_abap_unit_assert=>assert_equals(
      exp = 0 act = lo_second->get_call_count( )
      msg = 'second credential must not be tried once the first succeeds' ).
  ENDMETHOD.

  METHOD falls_back_on_failure.
    DATA(lo_chain)  = NEW zcl_az_default_credential( iv_register_defaults = abap_false ).
    DATA(lo_first)  = NEW zcl_az_token_credential_fake( iv_fail = abap_true ).
    DATA(lo_second) = NEW zcl_az_token_credential_fake( iv_token = 'T2' ).
    lo_chain->add_credential( lo_first ).
    lo_chain->add_credential( lo_second ).

    DATA(lo_token) = lo_chain->zif_az_token_credential~get_token( iv_scope = 'scope' ).

    cl_abap_unit_assert=>assert_equals( exp = 'T2' act = lo_token->get_token( ) ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = lo_first->get_call_count( ) ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = lo_second->get_call_count( ) ).
  ENDMETHOD.

  METHOD all_fail_raises.
    DATA(lo_chain) = NEW zcl_az_default_credential( iv_register_defaults = abap_false ).
    lo_chain->add_credential( NEW zcl_az_token_credential_fake( iv_fail = abap_true ) ).
    lo_chain->add_credential( NEW zcl_az_token_credential_fake( iv_fail = abap_true ) ).
    TRY.
        lo_chain->zif_az_token_credential~get_token( iv_scope = 'scope' ).
        cl_abap_unit_assert=>fail( 'expected zcx_az_auth_error when all credentials fail' ).
      CATCH zcx_az_auth_error.
        " expected
    ENDTRY.
  ENDMETHOD.

  METHOD empty_chain_raises.
    DATA(lo_chain) = NEW zcl_az_default_credential( iv_register_defaults = abap_false ).
    TRY.
        lo_chain->zif_az_token_credential~get_token( iv_scope = 'scope' ).
        cl_abap_unit_assert=>fail( 'expected zcx_az_auth_error for an empty chain' ).
      CATCH zcx_az_auth_error.
        " expected
    ENDTRY.
  ENDMETHOD.

  METHOD empty_scope_raises.
    DATA(lo_chain) = NEW zcl_az_default_credential( iv_register_defaults = abap_false ).
    TRY.
        lo_chain->zif_az_token_credential~get_token( iv_scope = '' ).
        cl_abap_unit_assert=>fail( 'expected zcx_az_auth_error for empty scope' ).
      CATCH zcx_az_auth_error.
        " expected
    ENDTRY.
  ENDMETHOD.

ENDCLASS.
