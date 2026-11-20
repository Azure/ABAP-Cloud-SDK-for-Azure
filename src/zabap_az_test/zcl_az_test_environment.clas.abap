* Copyright (c) Microsoft Corporation.
* Licensed under the MIT license.

CLASS zcl_az_test_environment DEFINITION

  PUBLIC
  FINAL
  CREATE PRIVATE.

  PUBLIC SECTION.


    CLASS-METHODS get_instance
      RETURNING VALUE(ro_instance) TYPE REF TO zcl_az_test_environment.

    "! Override any environment value at runtime (e.g. read the secret from a
    "! secure store in your test setup) instead of hard-coding it.
    METHODS configure
      IMPORTING
        iv_subscription_id TYPE string OPTIONAL
        iv_tenant_id       TYPE string OPTIONAL
        iv_client_id       TYPE string OPTIONAL
        iv_client_secret   TYPE string OPTIONAL.

    METHODS get_subscription_id  RETURNING VALUE(rv_value) TYPE string.
    METHODS get_tenant_id        RETURNING VALUE(rv_value) TYPE string.
    METHODS get_client_id        RETURNING VALUE(rv_value) TYPE string.
    METHODS get_client_secret    RETURNING VALUE(rv_value) TYPE string.
    METHODS get_primary_region   RETURNING VALUE(rv_value) TYPE string.
    METHODS get_secondary_region RETURNING VALUE(rv_value) TYPE string.
    METHODS get_arm_endpoint     RETURNING VALUE(rv_value) TYPE string.

    "! True once real values have been supplied (so integration tests can self-skip).
    METHODS is_configured
      RETURNING VALUE(rv_configured) TYPE abap_bool.

    "! Client-secret credential built from this environment.
    METHODS create_credential
      RETURNING VALUE(ro_credential) TYPE REF TO zif_az_token_credential.

    "! Compute client pointed at ARM. Pass io_http_client to inject a transport
    "! double in unit tests; omit it to talk to real Azure in integration tests.
    METHODS create_compute_client
      IMPORTING io_http_client   TYPE REF TO zif_az_http_client OPTIONAL
      RETURNING VALUE(ro_client) TYPE REF TO zif_az_compute_service.

    "! A request DTO pre-seeded with this environment's subscription + region.
    METHODS new_request
      RETURNING VALUE(ro_request) TYPE REF TO zcl_az_test_env_request.

  PRIVATE SECTION.

    CLASS-DATA go_instance TYPE REF TO zcl_az_test_environment.

    " ===== FILL IN your test environment (placeholders by default) =====
    " IDs are not secrets, but keep the client secret blank and inject it at
    " runtime via configure( ) — do not commit a real secret to source control.
    CONSTANTS c_subscription_id   TYPE string VALUE ''.
    CONSTANTS c_tenant_id         TYPE string VALUE ''.
    CONSTANTS c_client_id         TYPE string VALUE ''.
    CONSTANTS c_client_secret     TYPE string VALUE ''.
    CONSTANTS c_primary_region    TYPE string VALUE 'westeurope'.
    CONSTANTS c_secondary_region  TYPE string VALUE 'northeurope'.
    CONSTANTS c_arm_endpoint      TYPE string VALUE 'https://management.azure.com'.

    " runtime overrides (win over the constants when set)
    DATA mv_subscription_id TYPE string.
    DATA mv_tenant_id       TYPE string.
    DATA mv_client_id       TYPE string.
    DATA mv_client_secret   TYPE string.

ENDCLASS.



CLASS zcl_az_test_environment IMPLEMENTATION.

  METHOD get_instance.
    IF go_instance IS INITIAL.
      go_instance = NEW #( ).
    ENDIF.
    ro_instance = go_instance.
  ENDMETHOD.

  METHOD configure.
    IF iv_subscription_id IS NOT INITIAL. mv_subscription_id = iv_subscription_id. ENDIF.
    IF iv_tenant_id       IS NOT INITIAL. mv_tenant_id       = iv_tenant_id.       ENDIF.
    IF iv_client_id       IS NOT INITIAL. mv_client_id       = iv_client_id.       ENDIF.
    IF iv_client_secret   IS NOT INITIAL. mv_client_secret   = iv_client_secret.   ENDIF.
  ENDMETHOD.

  METHOD get_subscription_id.
    rv_value = COND #( WHEN mv_subscription_id IS NOT INITIAL THEN mv_subscription_id ELSE c_subscription_id ).
  ENDMETHOD.

  METHOD get_tenant_id.
    rv_value = COND #( WHEN mv_tenant_id IS NOT INITIAL THEN mv_tenant_id ELSE c_tenant_id ).
  ENDMETHOD.

  METHOD get_client_id.
    rv_value = COND #( WHEN mv_client_id IS NOT INITIAL THEN mv_client_id ELSE c_client_id ).
  ENDMETHOD.

  METHOD get_client_secret.
    rv_value = COND #( WHEN mv_client_secret IS NOT INITIAL THEN mv_client_secret ELSE c_client_secret ).
  ENDMETHOD.

  METHOD get_primary_region.
    rv_value = c_primary_region.
  ENDMETHOD.

  METHOD get_secondary_region.
    rv_value = c_secondary_region.
  ENDMETHOD.

  METHOD get_arm_endpoint.
    rv_value = c_arm_endpoint.
  ENDMETHOD.

  METHOD is_configured.
    " configured = a real (non-placeholder) subscription id is present
    rv_configured = boolc( get_subscription_id( ) NP '0000*' ).
  ENDMETHOD.

  METHOD create_credential.
    ro_credential = NEW zcl_az_client_secret_cred(
                      iv_client_id     = get_client_id( )
                      iv_client_secret = get_client_secret( )
                      iv_tenant_id     = get_tenant_id( ) ).
  ENDMETHOD.

  METHOD create_compute_client.
    ro_client = NEW zcl_az_compute_client(
                  iv_endpoint    = get_arm_endpoint( )
                  io_credential  = create_credential( )
                  io_http_client = io_http_client ).
  ENDMETHOD.

  METHOD new_request.
    ro_request                 = NEW zcl_az_test_env_request( ).
    ro_request->subscription_id = get_subscription_id( ).
    ro_request->location        = c_primary_region.
  ENDMETHOD.

ENDCLASS.
