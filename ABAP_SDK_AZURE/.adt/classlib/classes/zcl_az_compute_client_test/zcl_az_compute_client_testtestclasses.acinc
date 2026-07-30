*"* use this source file for your ABAP unit test classes

CLASS ltc_compute_client DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.

    DATA mo_http TYPE REF TO zcl_az_http_client_mock.
    DATA mo_cred TYPE REF TO zcl_az_token_credential_fake.
    DATA mo_cut  TYPE REF TO zif_az_compute_service.

    METHODS setup.

    "! 200 + JSON body deserializes into the typed value[] table.
    METHODS list_parses_vms             FOR TESTING RAISING zcx_azure.
    "! Path params substituted, query string built, bearer scope requested.
    METHODS list_builds_request         FOR TESTING RAISING zcx_azure.
    "! Persistent server error surfaces as a typed zcx_azure (retry exhaustion).
    METHODS server_error_is_raised      FOR TESTING.
    "! Transient 503 then 200 -> transport hit twice (retry actually re-runs).
    METHODS retry_then_succeeds         FOR TESTING RAISING zcx_azure.
    "! Action call builds a body-less POST to .../start.
    METHODS start_builds_post_request   FOR TESTING RAISING zcx_azure.

ENDCLASS.


CLASS ltc_compute_client IMPLEMENTATION.

  METHOD setup.
    mo_http = NEW zcl_az_http_client_mock( ).
    mo_cred = NEW zcl_az_token_credential_fake( ).
    mo_cut  = NEW zcl_az_compute_client(
                  iv_endpoint    = 'https://management.azure.com'
                  io_credential  = mo_cred
                  io_http_client = mo_http ).
  ENDMETHOD.


  METHOD list_parses_vms.

    mo_http->add_response(
      iv_status = 200
      iv_body   = `{"value":[{"name":"vm1","location":"eastus"},`
               && `{"name":"vm2","location":"westeurope"}]}` ).

    DATA(ls_result) = mo_cut->virtualmachines_list(
      api_version         = '2025-11-01'
      subscription_id     = 'sub'
      resource_group_name = 'rg' ).

    cl_abap_unit_assert=>assert_equals(
      exp = 200 act = ls_result-code msg = 'HTTP code not surfaced' ).
    cl_abap_unit_assert=>assert_equals(
      exp = 2   act = lines( ls_result-_200_app_json-value )
      msg = 'value[] not deserialized' ).
    cl_abap_unit_assert=>assert_equals(
      exp = 'vm1' act = ls_result-_200_app_json-value[ 1 ]-name ).
    cl_abap_unit_assert=>assert_equals(
      exp = 'westeurope' act = ls_result-_200_app_json-value[ 2 ]-location ).

  ENDMETHOD.


  METHOD list_builds_request.

    mo_http->add_response( iv_status = 200 iv_body = `{"value":[]}` ).

    mo_cut->virtualmachines_list(
      api_version         = '2025-11-01'
      subscription_id     = 'SUB'
      resource_group_name = 'RG' ).

    DATA(lo_req) = mo_http->get_last_request( ).

    cl_abap_unit_assert=>assert_equals( exp = 'GET' act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_char_cp(
      exp = '*/subscriptions/SUB/resourceGroups/RG/*Microsoft.Compute/virtualMachines*api-version=2025-11-01*'
      act = lo_req->mv_url
      msg = 'URL/path/query not built correctly' ).
    " the auth policy asked the credential for the client's default ARM scope
    cl_abap_unit_assert=>assert_equals(
      exp = 'https://management.azure.com/.default'
      act = mo_cred->get_scope_seen( ) ).

  ENDMETHOD.


  METHOD server_error_is_raised.

    mo_http->add_response( iv_status = 500 iv_body = `{"error":{"code":"Boom"}}` ).

    TRY.
        mo_cut->virtualmachines_get(
          vm_name             = 'x'
          api_version         = '2025-11-01'
          subscription_id     = 's'
          resource_group_name = 'r' ).
        cl_abap_unit_assert=>fail( 'expected an exception for HTTP 500' ).
      CATCH zcx_azure.
        " expected: retry exhaustion -> zcx_az_http_error (subclass of zcx_azure)
    ENDTRY.

  ENDMETHOD.


  METHOD retry_then_succeeds.

    mo_http->add_response( iv_status = 503 ).                       " attempt 1: transient
    mo_http->add_response( iv_status = 200 iv_body = `{"value":[]}` ). " attempt 2: ok

    mo_cut->virtualmachines_list(
      api_version         = '2025-11-01'
      subscription_id     = 's'
      resource_group_name = 'r' ).

    cl_abap_unit_assert=>assert_equals(
      exp = 2 act = mo_http->get_call_count( )
      msg = 'pipeline did not retry (context immutability regression?)' ).

  ENDMETHOD.


  METHOD start_builds_post_request.

    mo_http->add_response( iv_status = 202 iv_content_type = '' ).

    mo_cut->virtualmachines_start(
      vm_name             = 'vm1'
      api_version         = '2025-11-01'
      subscription_id     = 's'
      resource_group_name = 'r' ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'POST' act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_char_cp(
      exp = '*virtualMachines/vm1/start*'
      act = lo_req->mv_url ).
    " NOTE: the Content-Length:0 fix for body-less POST lives in zcl_az_http_client
    " (the real transport, bypassed by this mock) -> assert that in a transport test.

  ENDMETHOD.

ENDCLASS.


"----------------------------------------------------------------------
" Parameterized test driven by ZCL_AZ_TEST_ENV_REQUEST / ZCL_AZ_TEST_ENVIRONMENT.
" Still deterministic: the transport is mocked; only the *inputs* (subscription,
" resource group, vm name, api-version) come from the request DTO.
"----------------------------------------------------------------------
CLASS ltc_compute_parameterized DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    DATA mo_http TYPE REF TO zcl_az_http_client_mock.
    DATA mo_req  TYPE REF TO zcl_az_test_env_request.
    DATA mo_cut  TYPE REF TO zif_az_compute_service.

    METHODS setup.
    METHODS list_uses_request_inputs FOR TESTING RAISING zcx_azure.
ENDCLASS.

CLASS ltc_compute_parameterized IMPLEMENTATION.

  METHOD setup.
    mo_http = NEW zcl_az_http_client_mock( ).
    " key in the environment here (or via ZCL_AZ_TEST_ENVIRONMENT->new_request)
    mo_req  = NEW zcl_az_test_env_request( ).
    mo_req->subscription_id     = 'SUB-123'.
    mo_req->resource_group_name = 'rg_demo'.
    mo_req->vm_name             = 'vm-demo'.
    " transport injected -> deterministic, no real Azure
    " Both seams must be doubled for an offline unit test: the mock transport
    " (io_http_client) AND a fake credential.
    mo_cut = NEW zcl_az_compute_client(
                 iv_endpoint    = 'https://management.azure.com'
                 io_credential  = NEW zcl_az_token_credential_fake( )
                 io_http_client = mo_http ).
  ENDMETHOD.

  METHOD list_uses_request_inputs.
    mo_http->add_response( iv_status = 200 iv_body = `{"value":[]}` ).

    mo_cut->virtualmachines_list(
      api_version         = mo_req->api_version
      subscription_id     = mo_req->subscription_id
      resource_group_name = mo_req->resource_group_name ).

    cl_abap_unit_assert=>assert_char_cp(
      exp = '*/subscriptions/SUB-123/resourceGroups/rg_demo/*api-version=2025-11-01*'
      act = mo_http->get_last_request( )->mv_url ).
  ENDMETHOD.

ENDCLASS.


"----------------------------------------------------------------------
" Integration test against REAL Azure. Self-skips unless ZCL_AZ_TEST_ENVIRONMENT
" is configured (real subscription + secret). Read-only (lists VMs). RISK LEVEL
" DANGEROUS so it only runs when the system explicitly allows it.
"----------------------------------------------------------------------
CLASS ltc_compute_integration DEFINITION FINAL FOR TESTING
  DURATION LONG
  RISK LEVEL DANGEROUS.

  PRIVATE SECTION.
    METHODS list_vms_real FOR TESTING RAISING zcx_azure.
ENDCLASS.

CLASS ltc_compute_integration IMPLEMENTATION.

  METHOD list_vms_real.
    DATA(lo_env) = zcl_az_test_environment=>get_instance( ).
    " set the secret at runtime (e.g. from a secure store) before running:
    " lo_env->configure( iv_client_secret = '...' ).
    IF lo_env->is_configured( ) = abap_false.
      RETURN.   " not configured -> skip quietly
    ENDIF.

    DATA(lo_req)    = lo_env->new_request( ).
    lo_req->resource_group_name = 'rg_test'.   " adjust to your env
    DATA(lo_client) = lo_env->create_compute_client( ).   " real transport

    DATA(ls_result) = lo_client->virtualmachines_list(
      api_version         = lo_req->api_version
      subscription_id     = lo_req->subscription_id
      resource_group_name = lo_req->resource_group_name ).

    cl_abap_unit_assert=>assert_equals( exp = 200 act = ls_result-code ).
  ENDMETHOD.

ENDCLASS.


"----------------------------------------------------------------------
" Broad method/edge-case coverage for the generated compute surface. All
" mocked (deterministic, offline). Exercises a diverse set of operation
" SHAPES rather than every one of the 189 methods: typed GET, GET with an
" optional query param (present/absent), PUT with a serialized body +
" conditional headers, DELETE with an optional bool query, body-less POST
" actions, subscription/provider/location-scoped lists, and the error /
" retry / transport-failure paths shared by every generated method.
"----------------------------------------------------------------------
CLASS ltc_compute_methods DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.

    CONSTANTS c_api TYPE string VALUE '2025-11-01'.

    DATA mo_http TYPE REF TO zcl_az_http_client_mock.
    DATA mo_cut  TYPE REF TO zif_az_compute_service.

    METHODS setup.

    " ---- GET (single resource) ----
    "! 200 + JSON object deserializes into the typed _200 structure.
    METHODS get_returns_typed_vm        FOR TESTING RAISING zcx_azure.
    "! GET path + verb + api-version built correctly.
    METHODS get_builds_get_request      FOR TESTING RAISING zcx_azure.
    "! optional $expand query appears only when supplied.
    METHODS get_appends_expand          FOR TESTING RAISING zcx_azure.
    METHODS get_omits_expand_when_blank FOR TESTING RAISING zcx_azure.

    " ---- PUT (createOrUpdate, body) ----
    "! body is JSON-serialized into mv_body and sent as PUT.
    METHODS createorupdate_puts_body    FOR TESTING RAISING zcx_azure.
    "! conditional If-Match header is propagated.
    METHODS createorupdate_if_match     FOR TESTING RAISING zcx_azure.

    " ---- DELETE (optional bool query) ----
    METHODS delete_uses_delete_verb     FOR TESTING RAISING zcx_azure.
    METHODS delete_appends_force        FOR TESTING RAISING zcx_azure.

    " ---- POST actions (body-less) ----
    METHODS deallocate_posts_action     FOR TESTING RAISING zcx_azure.
    METHODS restart_posts_action        FOR TESTING RAISING zcx_azure.
    METHODS poweroff_posts_action       FOR TESTING RAISING zcx_azure.

    " ---- list scopes ----
    "! subscription-scoped list (no resourceGroups segment).
    METHODS listall_subscription_scope  FOR TESTING RAISING zcx_azure.
    "! optional $filter on the subscription-scoped list.
    METHODS listall_appends_filter      FOR TESTING RAISING zcx_azure.
    "! provider-scoped list (operations: only api-version).
    METHODS operations_provider_scope   FOR TESTING RAISING zcx_azure.
    "! location-scoped list (vmSizes).
    METHODS sizes_list_by_location      FOR TESTING RAISING zcx_azure.
    "! sub-resource GET (instance view).
    METHODS instanceview_subresource    FOR TESTING RAISING zcx_azure.

    " ---- error / retry / transport edge cases ----
    "! 404 is retried to exhaustion then surfaces a typed zcx_azure.
    METHODS not_found_raises            FOR TESTING.
    "! a 4xx client error also surfaces as a typed zcx_azure.
    METHODS bad_request_raises          FOR TESTING.
    "! a transport-layer exception surfaces as a typed zcx_azure.
    METHODS transport_error_raises      FOR TESTING.
    "! 2xx non-200 (202 Accepted, empty body) is a success, not an error.
    METHODS accepted_202_succeeds       FOR TESTING RAISING zcx_azure.

ENDCLASS.


CLASS ltc_compute_methods IMPLEMENTATION.

  METHOD setup.
    mo_http = NEW zcl_az_http_client_mock( ).
    " offline unit test -> double BOTH HTTP seams: mock transport AND a fake
    " credential (a real credential would call Azure's token endpoint).
    mo_cut  = NEW zcl_az_compute_client(
                  iv_endpoint    = 'https://management.azure.com'
                  io_credential  = NEW zcl_az_token_credential_fake( )
                  io_http_client = mo_http ).
  ENDMETHOD.

  "===================== GET =====================

  METHOD get_returns_typed_vm.
    mo_http->add_response( iv_status = 200
      iv_body = `{"name":"vm9","location":"eastus","id":"/subscriptions/s/.../vm9"}` ).

    DATA(ls) = mo_cut->virtualmachines_get(
      vm_name = 'vm9' api_version = c_api subscription_id = 's' resource_group_name = 'r' ).

    cl_abap_unit_assert=>assert_equals( exp = 200      act = ls-code ).
    cl_abap_unit_assert=>assert_equals( exp = 'vm9'    act = ls-_200_app_json-name ).
    cl_abap_unit_assert=>assert_equals( exp = 'eastus' act = ls-_200_app_json-location ).
  ENDMETHOD.

  METHOD get_builds_get_request.
    mo_http->add_response( iv_status = 200 iv_body = `{}` ).

    mo_cut->virtualmachines_get(
      vm_name = 'vm1' api_version = c_api subscription_id = 'SUB' resource_group_name = 'RG' ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'GET' act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_char_cp(
      exp = '*/subscriptions/SUB/resourceGroups/RG/*virtualMachines/vm1*api-version=2025-11-01*'
      act = lo_req->mv_url ).
  ENDMETHOD.

  METHOD get_appends_expand.
    mo_http->add_response( iv_status = 200 iv_body = `{}` ).

    mo_cut->virtualmachines_get(
      vm_name = 'vm1' _expand = 'instanceView'
      api_version = c_api subscription_id = 's' resource_group_name = 'r' ).

    cl_abap_unit_assert=>assert_char_cp(
      exp = '*$expand=instanceView*'
      act = mo_http->get_last_request( )->mv_url ).
  ENDMETHOD.

  METHOD get_omits_expand_when_blank.
    mo_http->add_response( iv_status = 200 iv_body = `{}` ).

    mo_cut->virtualmachines_get(
      vm_name = 'vm1' api_version = c_api subscription_id = 's' resource_group_name = 'r' ).

    cl_abap_unit_assert=>assert_false(
      act = boolc( mo_http->get_last_request( )->mv_url CS '$expand' )
      msg = '$expand must not appear when not supplied' ).
  ENDMETHOD.

  "===================== PUT (createOrUpdate) =====================

  METHOD createorupdate_puts_body.
    mo_http->add_response( iv_status = 200 iv_body = `{"name":"vm1"}` ).

    DATA ls_vm TYPE zif_az_compute_service=>virtual_machine.
    ls_vm-location = 'eastus'.

    mo_cut->virtualmachines_createorupdate(
      vm_name = 'vm1' body = ls_vm
      api_version = c_api subscription_id = 's' resource_group_name = 'r' ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'PUT' act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_not_initial( lo_req->mv_body ).
    cl_abap_unit_assert=>assert_char_cp(
      exp = '*eastus*' act = lo_req->mv_body
      msg = 'request body was not JSON-serialized' ).
    READ TABLE lo_req->mt_headers
      WITH KEY table_line = 'Content-Type:application/json' TRANSPORTING NO FIELDS.
    cl_abap_unit_assert=>assert_subrc( msg = 'JSON content-type header missing' ).
  ENDMETHOD.

  METHOD createorupdate_if_match.
    mo_http->add_response( iv_status = 200 iv_body = `{}` ).

    DATA ls_vm TYPE zif_az_compute_service=>virtual_machine.
    mo_cut->virtualmachines_createorupdate(
      vm_name = 'vm1' body = ls_vm if__match = 'W/"etag-1"'
      api_version = c_api subscription_id = 's' resource_group_name = 'r' ).

    READ TABLE mo_http->get_last_request( )->mt_headers
      WITH KEY table_line = 'If-Match:W/"etag-1"' TRANSPORTING NO FIELDS.
    cl_abap_unit_assert=>assert_subrc( msg = 'If-Match header not propagated' ).
  ENDMETHOD.

  "===================== DELETE =====================

  METHOD delete_uses_delete_verb.
    mo_http->add_response( iv_status = 200 ).

    mo_cut->virtualmachines_delete(
      vm_name = 'vm1' api_version = c_api subscription_id = 's' resource_group_name = 'r' ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'DELETE' act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_char_cp( exp = '*virtualMachines/vm1*' act = lo_req->mv_url ).
  ENDMETHOD.

  METHOD delete_appends_force.
    mo_http->add_response( iv_status = 200 ).

    mo_cut->virtualmachines_delete(
      vm_name = 'vm1' force_deletion = abap_true
      api_version = c_api subscription_id = 's' resource_group_name = 'r' ).

    cl_abap_unit_assert=>assert_char_cp(
      exp = '*forceDeletion=*' act = mo_http->get_last_request( )->mv_url ).
  ENDMETHOD.

  "===================== POST actions =====================

  METHOD deallocate_posts_action.
    mo_http->add_response( iv_status = 202 iv_content_type = '' ).

    mo_cut->virtualmachines_deallocate(
      vm_name = 'vm1' api_version = c_api subscription_id = 's' resource_group_name = 'r' ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'POST' act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_char_cp( exp = '*virtualMachines/vm1/deallocate*' act = lo_req->mv_url ).
  ENDMETHOD.

  METHOD restart_posts_action.
    mo_http->add_response( iv_status = 202 iv_content_type = '' ).

    mo_cut->virtualmachines_restart(
      vm_name = 'vm1' api_version = c_api subscription_id = 's' resource_group_name = 'r' ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'POST' act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_char_cp( exp = '*virtualMachines/vm1/restart*' act = lo_req->mv_url ).
  ENDMETHOD.

  METHOD poweroff_posts_action.
    mo_http->add_response( iv_status = 202 iv_content_type = '' ).

    mo_cut->virtualmachines_poweroff(
      vm_name = 'vm1' api_version = c_api subscription_id = 's' resource_group_name = 'r' ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'POST' act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_char_cp( exp = '*virtualMachines/vm1/powerOff*' act = lo_req->mv_url ).
  ENDMETHOD.

  "===================== list scopes =====================

  METHOD listall_subscription_scope.
    mo_http->add_response( iv_status = 200 iv_body = `{"value":[]}` ).

    mo_cut->virtualmachines_listall( api_version = c_api subscription_id = 'SUB' ).

    DATA(lv_url) = mo_http->get_last_request( )->mv_url.
    cl_abap_unit_assert=>assert_char_cp(
      exp = '*/subscriptions/SUB/providers/Microsoft.Compute/virtualMachines*' act = lv_url ).
    " subscription-wide list must NOT carry a resourceGroups segment
    cl_abap_unit_assert=>assert_false( act = boolc( lv_url CS 'resourceGroups' ) ).
  ENDMETHOD.

  METHOD listall_appends_filter.
    mo_http->add_response( iv_status = 200 iv_body = `{"value":[]}` ).

    mo_cut->virtualmachines_listall(
      _filter = `location eq 'eastus'` api_version = c_api subscription_id = 's' ).

    cl_abap_unit_assert=>assert_char_cp(
      exp = '*$filter=*' act = mo_http->get_last_request( )->mv_url ).
  ENDMETHOD.

  METHOD operations_provider_scope.
    mo_http->add_response( iv_status = 200 iv_body = `{"value":[]}` ).

    mo_cut->operations_list( api_version = c_api ).

    DATA(lv_url) = mo_http->get_last_request( )->mv_url.
    cl_abap_unit_assert=>assert_char_cp(
      exp = '*/providers/Microsoft.Compute/operations*api-version=2025-11-01*' act = lv_url ).
    cl_abap_unit_assert=>assert_false( act = boolc( lv_url CS '/subscriptions/' ) ).
  ENDMETHOD.

  METHOD sizes_list_by_location.
    mo_http->add_response( iv_status = 200 iv_body = `{"value":[]}` ).

    mo_cut->virtualmachinesizes_list(
      location = 'eastus' api_version = c_api subscription_id = 's' ).

    cl_abap_unit_assert=>assert_char_cp(
      exp = '*/locations/eastus/vmSizes*' act = mo_http->get_last_request( )->mv_url ).
  ENDMETHOD.

  METHOD instanceview_subresource.
    mo_http->add_response( iv_status = 200 iv_body = `{}` ).

    mo_cut->virtualmachines_instanceview(
      vm_name = 'vm1' api_version = c_api subscription_id = 's' resource_group_name = 'r' ).

    cl_abap_unit_assert=>assert_char_cp(
      exp = '*virtualMachines/vm1/instanceView*' act = mo_http->get_last_request( )->mv_url ).
  ENDMETHOD.

  "===================== error / retry / transport =====================

  METHOD not_found_raises.
    mo_http->add_response( iv_status = 404 iv_body = `{"error":{"code":"NotFound"}}` ).

    TRY.
        mo_cut->virtualmachines_get(
          vm_name = 'gone' api_version = c_api subscription_id = 's' resource_group_name = 'r' ).
        cl_abap_unit_assert=>fail( 'expected zcx_azure for HTTP 404' ).
      CATCH zcx_azure.
        " a non-2xx is retried to exhaustion (3 attempts) then raised
        cl_abap_unit_assert=>assert_equals( exp = 3 act = mo_http->get_call_count( ) ).
    ENDTRY.
  ENDMETHOD.

  METHOD bad_request_raises.
    mo_http->add_response( iv_status = 400 iv_body = `{"error":{"code":"BadRequest"}}` ).

    TRY.
        mo_cut->virtualmachines_get(
          vm_name = 'x' api_version = c_api subscription_id = 's' resource_group_name = 'r' ).
        cl_abap_unit_assert=>fail( 'expected zcx_azure for HTTP 400' ).
      CATCH zcx_azure.
    ENDTRY.
  ENDMETHOD.

  METHOD transport_error_raises.
    mo_http->set_error( NEW zcx_az_http_error(
      iv_status_code = 0 iv_message = 'simulated socket failure' ) ).

    TRY.
        mo_cut->virtualmachines_get(
          vm_name = 'x' api_version = c_api subscription_id = 's' resource_group_name = 'r' ).
        cl_abap_unit_assert=>fail( 'expected zcx_azure for transport failure' ).
      CATCH zcx_azure.
    ENDTRY.
  ENDMETHOD.

  METHOD accepted_202_succeeds.
    " a 202 Accepted with no body is a success for an action method (no raise).
    mo_http->add_response( iv_status = 202 iv_content_type = '' ).

    DATA(ls) = mo_cut->virtualmachines_start(
      vm_name = 'vm1' api_version = c_api subscription_id = 's' resource_group_name = 'r' ).

    cl_abap_unit_assert=>assert_equals( exp = 202 act = ls-code ).
  ENDMETHOD.

ENDCLASS.
