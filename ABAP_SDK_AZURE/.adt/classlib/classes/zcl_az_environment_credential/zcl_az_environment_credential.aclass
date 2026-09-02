* Copyright (c) Microsoft Corporation.
* Licensed under the MIT license.

CLASS zcl_az_environment_credential DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC .

  PUBLIC SECTION.
    INTERFACES zif_az_token_credential.

    METHODS constructor
      IMPORTING io_http_client TYPE REF TO zif_az_http_client OPTIONAL.

  PRIVATE SECTION.
    DATA mo_http_client TYPE REF TO zif_az_http_client.

    METHODS get_env_value
      IMPORTING
        iv_name         TYPE string
      RETURNING
        VALUE(rv_value) TYPE string.

ENDCLASS.



CLASS ZCL_AZ_ENVIRONMENT_CREDENTIAL IMPLEMENTATION.

  METHOD constructor.
    mo_http_client = io_http_client.
  ENDMETHOD.

  METHOD get_env_value.
    " Read configuration value from an own, released Z config table.
    " Standard tables like TVARVC are not permitted, so use a custom table.
    SELECT SINGLE value
      FROM zaz_config
      WHERE name = @iv_name
      INTO @rv_value.
  ENDMETHOD.


  METHOD zif_az_token_credential~get_token.

    DATA lv_client_id TYPE string.
    DATA lv_secret    TYPE string.
    DATA lv_tenant    TYPE string.

    " Guard: scope must not be empty
    IF iv_scope IS INITIAL.
      RAISE EXCEPTION TYPE zcx_az_auth_error
        EXPORTING
          iv_message = |Cannot authenticate: scope is empty.|.
    ENDIF.

    lv_client_id = get_env_value( |AZURE_CLIENT_ID| ).
    lv_secret    = get_env_value( |AZURE_CLIENT_SECRET| ).
    lv_tenant    = get_env_value( |AZURE_TENANT_ID| ).

    " Guard: required configuration values must be present
    IF lv_client_id IS INITIAL.
      RAISE EXCEPTION TYPE zcx_az_auth_error
        EXPORTING
          iv_message = |Environment credential: AZURE_CLIENT_ID is not set.|.
    ENDIF.

    IF lv_secret IS INITIAL.
      RAISE EXCEPTION TYPE zcx_az_auth_error
        EXPORTING
          iv_message = |Environment credential: AZURE_CLIENT_SECRET is not set.|.
    ENDIF.

    IF lv_tenant IS INITIAL.
      RAISE EXCEPTION TYPE zcx_az_auth_error
        EXPORTING
          iv_message = |Environment credential: AZURE_TENANT_ID is not set.|.
    ENDIF.

    TRY.
        DATA lo_cred TYPE REF TO zif_az_token_credential.

        lo_cred = NEW zcl_az_client_secret_cred(
                    iv_client_id     = lv_client_id
                    iv_client_secret = lv_secret
                    iv_tenant_id     = lv_tenant
                    io_http_client   = mo_http_client ).

        ro_token = lo_cred->get_token( iv_scope = iv_scope ).

        " Defensive: a valid token must be returned
        IF ro_token IS NOT BOUND.
          RAISE EXCEPTION TYPE zcx_az_auth_error
            EXPORTING
              iv_message = |Environment credential: no access token returned.|.
        ENDIF.


      CATCH zcx_az_auth_error INTO DATA(lx_auth).
        RAISE EXCEPTION lx_auth.

      CATCH cx_root INTO DATA(lx_root).
        RAISE EXCEPTION TYPE zcx_az_auth_error
          EXPORTING
            iv_message = |Environment credential: failed to acquire token.|
            previous   = lx_root.
    ENDTRY.

  ENDMETHOD.

ENDCLASS.
