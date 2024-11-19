#!/usr/bin/env python3

import boto3
import sys
import os
import datetime


try:
    bucket_name = sys.argv[1]
    build_name = sys.argv[2]
    source_dir = sys.argv[3]
    dest_dir = sys.argv[4]

    conn = boto3.client('s3')
    file_dir_once_uploaded = "{0}/{1}-{2}".format(dest_dir, datetime.datetime.now().date().isoformat(), build_name)
    for root, subFolders, files in os.walk(source_dir):
        for file in files:
            local_file_path = os.path.join(root, file)
            target_upload_file_path = "{0}/{1}".format(file_dir_once_uploaded, os.path.relpath(local_file_path, source_dir))
            print("{0} => {1}".format(local_file_path, target_upload_file_path), file=sys.stderr)
            if target_upload_file_path.endswith(".html"):
                content_type = "text/html"
            elif target_upload_file_path.endswith(".svg"):
                content_type = "image/svg+xml"
            elif target_upload_file_path.endswith(".png"):
                content_type = "image/png"
            else:
                content_type = "application/octet-stream"
            conn.upload_file(
                local_file_path, bucket_name, target_upload_file_path,
                ExtraArgs={'ACL': 'public-read', "ContentType": content_type, "ContentDisposition": "inline"}
            )

    print("http://{0}.s3-website-{1}.amazonaws.com/{2}".format(bucket_name, "us-east-1", file_dir_once_uploaded))

except Exception as e:
    print("Error uploading files: {0}".format(e))
