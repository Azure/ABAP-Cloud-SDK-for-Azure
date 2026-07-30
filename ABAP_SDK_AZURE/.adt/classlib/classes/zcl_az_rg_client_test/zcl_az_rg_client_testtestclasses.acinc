*"* use this source file for your ABAP unit test classes

CLASS ltc_rg_client DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    DATA mo_http TYPE REF TO zcl_az_http_client_mock.
    DATA mo_cut  TYPE REF TO zif_az_resourcegraph_service.

    METHODS setup.
    "! 200 + query JSON -> result populated (raw row captured).
    METHODS parses_query_result  FOR TESTING RAISING zcx_azure.
    "! POSTs the ARM ResourceGraph endpoint with the query in the body.
    METHODS builds_post_request  FOR TESTING RAISING zcx_azure.
    "! Service error surfaces as a typed zcx_azure.
    METHODS service_error_raises FOR TESTING.

    " ---- generated full-surface methods (resources / operations_list) ----
    "! resources(): 200 JSON deserializes into the typed query_response.
    METHODS resources_typed_response FOR TESTING RAISING zcx_azure.
    "! resources(): POST to /resources with the query_request serialized as body.
    METHODS resources_builds_post    FOR TESTING RAISING zcx_azure.
    "! resources(): a non-2xx surfaces as a typed zcx_azure.
    METHODS resources_error_raises   FOR TESTING.
    "! operations_list(): GET /operations, typed operation_list_result.
    METHODS operations_list_get      FOR TESTING RAISING zcx_azure.
ENDCLASS.


CLASS ltc_rg_client IMPLEMENTATION.

  METHOD setup.
    mo_http = NEW zcl_az_http_client_mock( ).
    mo_cut  = NEW zcl_az_resourcegraph_client(
                io_credential  = NEW zcl_az_token_credential_fake( )
                io_http_client = mo_http ).
  ENDMETHOD.

  METHOD parses_query_result.
    mo_http->add_response(
      iv_status = 200
      iv_body   = `{"totalRecords":2,"count":2,"resultTruncated":false,`
               && `"data":[{"name":"r1"},{"name":"r2"}]}` ).

    DATA(lo_result) = mo_cut->query_resources( iv_query = 'Resources | project name' ).

    cl_abap_unit_assert=>assert_bound( lo_result ).
    " the client always captures the raw payload row (deterministic)
    cl_abap_unit_assert=>assert_equals( exp = 1 act = lines( lo_result->mt_rows ) ).
    cl_abap_unit_assert=>assert_char_cp( exp = '*totalRecords*' act = lo_result->mt_rows[ 1 ] ).
  ENDMETHOD.

  METHOD builds_post_request.
    mo_http->add_response( iv_status = 200 iv_body = `{"totalRecords":0,"count":0}` ).

    mo_cut->query_resources(
      iv_query         = 'Resources'
      it_subscriptions = VALUE #( ( `sub-1` ) ) ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'POST' act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_char_cp(
      exp = '*Microsoft.ResourceGraph/resources*' act = lo_req->mv_url ).
    cl_abap_unit_assert=>assert_char_cp(
      exp = '*Resources*' act = lo_req->mv_body
      msg = 'query not serialized into the request body' ).
  ENDMETHOD.

  METHOD service_error_raises.
    mo_http->add_response( iv_status = 400 iv_body = `{"error":{"code":"BadQuery"}}` ).
    TRY.
        mo_cut->query_resources( iv_query = 'x' ).
        cl_abap_unit_assert=>fail( 'expected exception for HTTP 400' ).
      CATCH zcx_azure.
        " expected
    ENDTRY.
  ENDMETHOD.

  "=============== generated full-surface methods ===============

  " resources(): 200 JSON is deserialized into the typed query_response struct.
  METHOD resources_typed_response.
    mo_http->add_response( iv_status = 200
      iv_body = `{"totalRecords":42,"count":2,"resultTruncated":"false","data":"[]"}` ).

    DATA ls_body TYPE zif_az_resourcegraph_service=>query_request.
    ls_body-query = 'Resources | project name'.

    DATA(ls) = mo_cut->resources( api_version = '2024-04-01' body = ls_body ).

    cl_abap_unit_assert=>assert_equals( exp = 200 act = ls-code ).
    cl_abap_unit_assert=>assert_equals(
      exp = 42 act = ls-_200_app_json-total_records
      msg = 'query_response not deserialized' ).
    cl_abap_unit_assert=>assert_equals( exp = 2 act = ls-_200_app_json-count ).
  ENDMETHOD.

  " resources(): POST to /resources with the query_request serialized as the body.
  METHOD resources_builds_post.
    mo_http->add_response( iv_status = 200 iv_body = `{"totalRecords":0,"count":0}` ).

    DATA ls_body TYPE zif_az_resourcegraph_service=>query_request.
    ls_body-query         = 'Resources'.
    ls_body-subscriptions = VALUE #( ( `sub-1` ) ).

    mo_cut->resources( api_version = '2024-04-01' body = ls_body ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'POST' act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_char_cp(
      exp = '*Microsoft.ResourceGraph/resources*api-version=2024-04-01*' act = lo_req->mv_url ).
    cl_abap_unit_assert=>assert_char_cp(
      exp = '*sub-1*' act = lo_req->mv_body
      msg = 'query_request not JSON-serialized into the body' ).
    READ TABLE lo_req->mt_headers
      WITH KEY table_line = 'Content-Type:application/json' TRANSPORTING NO FIELDS.
    cl_abap_unit_assert=>assert_subrc( msg = 'JSON content-type header missing' ).
  ENDMETHOD.

  " resources(): a non-2xx surfaces as a typed zcx_azure.
  METHOD resources_error_raises.
    mo_http->add_response( iv_status = 403 iv_body = `{"error":{"code":"Forbidden"}}` ).

    DATA ls_body TYPE zif_az_resourcegraph_service=>query_request.
    ls_body-query = 'Resources'.

    TRY.
        mo_cut->resources( api_version = '2024-04-01' body = ls_body ).
        cl_abap_unit_assert=>fail( 'expected zcx_azure for HTTP 403' ).
      CATCH zcx_azure.
    ENDTRY.
  ENDMETHOD.

  " operations_list(): GET /operations, typed operation_list_result.
  METHOD operations_list_get.
    mo_http->add_response( iv_status = 200
      iv_body = `{"value":[{"name":"Microsoft.ResourceGraph/resources/read"}]}` ).

    DATA(ls) = mo_cut->operations_list( api_version = '2024-04-01' ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'GET' act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_char_cp(
      exp = '*Microsoft.ResourceGraph/operations*' act = lo_req->mv_url ).
    cl_abap_unit_assert=>assert_equals(
      exp = 1 act = lines( ls-_200_app_json-value )
      msg = 'operation_list_result not deserialized' ).
  ENDMETHOD.

ENDCLASS.


"----------------------------------------------------------------------
" Integration test against REAL Azure (no io_http_client -> live
" zcl_az_http_client). RISK LEVEL DANGEROUS; self-skips unless
" ZCL_AZ_TEST_ENVIRONMENT is configured (real subscription + secret).
" Read-only (runs a trivial 'Resources | limit 1' query).
"----------------------------------------------------------------------
CLASS ltc_rg_integration DEFINITION FINAL FOR TESTING
  DURATION LONG
  RISK LEVEL DANGEROUS.

  PRIVATE SECTION.
    DATA mo_env TYPE REF TO zcl_az_test_environment.
    DATA mo_cut TYPE REF TO zif_az_resourcegraph_service.

    METHODS setup.
    "! True only when a real subscription + client secret are present.
    METHODS configured RETURNING VALUE(rv) TYPE abap_bool.

    "! Ergonomic facade against live Azure: run a trivial query.
    METHODS query_resources_real FOR TESTING RAISING zcx_azure.
    "! Generated resources() against live Azure with a typed query_request.
    METHODS resources_real       FOR TESTING RAISING zcx_azure.
    "! Read-only operations_list() against live Azure.
    METHODS operations_list_real FOR TESTING RAISING zcx_azure.
ENDCLASS.


CLASS ltc_rg_integration IMPLEMENTATION.

  METHOD setup.
    mo_env = zcl_az_test_environment=>get_instance( ).
    " no io_http_client -> the real zcl_az_http_client is used (live Azure)
    mo_cut = NEW zcl_az_resourcegraph_client(
               io_credential = mo_env->create_credential( ) ).
  ENDMETHOD.

  METHOD configured.
    rv = boolc( mo_env->get_subscription_id( ) NP '0000*'
            AND mo_env->get_client_secret( ) IS NOT INITIAL ).
  ENDMETHOD.

  METHOD query_resources_real.
    IF configured( ) = abap_false. RETURN. ENDIF.
    DATA(lo_result) = mo_cut->query_resources(
      iv_query         = 'Resources | project name, type | limit 1'
      it_subscriptions = VALUE #( ( mo_env->get_subscription_id( ) ) ) ).
    cl_abap_unit_assert=>assert_bound( lo_result ).
  ENDMETHOD.

  METHOD resources_real.
    IF configured( ) = abap_false. RETURN. ENDIF.
    DATA ls_body TYPE zif_az_resourcegraph_service=>query_request.
    ls_body-query         = 'Resources | project name | limit 1'.
    ls_body-subscriptions = VALUE #( ( mo_env->get_subscription_id( ) ) ).

    DATA(ls) = mo_cut->resources( api_version = '2024-04-01' body = ls_body ).
    cl_abap_unit_assert=>assert_equals( exp = 200 act = ls-code ).
  ENDMETHOD.

  METHOD operations_list_real.
    IF configured( ) = abap_false. RETURN. ENDIF.
    DATA(ls) = mo_cut->operations_list( api_version = '2024-04-01' ).
    cl_abap_unit_assert=>assert_equals( exp = 200 act = ls-code ).
  ENDMETHOD.

ENDCLASS.
