* Copyright (c) Microsoft Corporation.
* Licensed under the MIT license.

CLASS zcl_az_upload_blob_result DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.

    "! Metadata returned by Put Blob (201 Created).
    DATA mv_etag          TYPE string.
    DATA mv_last_modified TYPE string.
    DATA mv_content_md5   TYPE string.
    DATA mv_version_id    TYPE string.

  PROTECTED SECTION.
  PRIVATE SECTION.
ENDCLASS.



CLASS zcl_az_upload_blob_result IMPLEMENTATION.
ENDCLASS.
