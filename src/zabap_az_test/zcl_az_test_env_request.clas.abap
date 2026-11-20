* Copyright (c) Microsoft Corporation.
* Licensed under the MIT license.

 "! Parameterizable description of a compute test environment — set the public
 "! attributes you care about and pass it to the helpers / client calls.

CLASS zcl_az_test_env_request DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.

    " --- targeting -------------------------------------------------------
    DATA subscription_id      TYPE string.
    DATA resource_group_name  TYPE string.
    DATA location             TYPE string    VALUE 'westeurope'.
    DATA api_version          TYPE string    VALUE '2025-11-01'.

    " --- virtual machine -------------------------------------------------
    DATA vm_name              TYPE string.
    DATA vm_count             TYPE i         VALUE 1.
    DATA vm_size              TYPE string    VALUE 'Standard_D2s_v3'.
    DATA vm_availability_zone TYPE string.
    DATA deploy_linux         TYPE abap_bool VALUE abap_true.
    DATA vm_linux_image       TYPE string    VALUE 'Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest'.
    DATA vm_windows_image     TYPE string    VALUE 'MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest'.

    " --- disks -----------------------------------------------------------
    DATA data_disk_count        TYPE i      VALUE 2.
    DATA data_disk_size_gb      TYPE i      VALUE 4.
    DATA os_disk_storage_type   TYPE string VALUE 'Premium_LRS'.
    DATA data_disk_storage_type TYPE string VALUE 'Premium_LRS'.
    DATA data_disk_caching_type TYPE string VALUE 'None'.

    " --- network ---------------------------------------------------------
    DATA nic_count             TYPE i      VALUE 1.
    DATA vm_ip_address_count   TYPE i      VALUE 1.
    DATA vnet_name             TYPE string VALUE 'vnet'.
    DATA subnet_name           TYPE string VALUE 'default'.
    DATA address_prefix        TYPE string VALUE '10.0.0.0/8'.
    DATA address_prefix_subnet TYPE string VALUE '10.0.0.0/24'.

ENDCLASS.



CLASS zcl_az_test_env_request IMPLEMENTATION.
ENDCLASS.
