from __future__ import annotations
import boto3

session = boto3.Session()  # uses AWS_PROFILE env var or default profile
sts = session.client("sts")
s3 = session.client("s3")

who = sts.get_caller_identity()
print("Caller:", who["Arn"])

# Optional: quick peek at your bucket/prefix just to prove access
bucket = "cur-695166363537-test"
prefix = "hourly/cur-695166363537/20240801-20240901/"
resp = s3.list_objects_v2(Bucket=bucket, Prefix=prefix, MaxKeys=10)
print("Sample keys:")
for o in resp.get("Contents", []):
    print(" -", o["Key"])
