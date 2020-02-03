import os
import json
import csv
import boto3
from http import HTTPStatus
from boxsdk import JWTAuth, Client

SECRET_NAME = os.getenv("SECRET_NAME")
BUCKET_NAME = os.getenv("BUCKET_NAME")

secretsmgr_client = boto3.client("secretsmanager")
s3_client = boto3.client("s3")


def lambda_handler(event: dict, context) -> None:
    # リクエストパース
    client, webhook_key = get_box_client()
    raw_body = event["body"]
    body = json.loads(raw_body)
    trigger = body["trigger"]
    webhook_id = body["webhook"]["id"]
    source = body["source"]
    parent = body["source"]["parent"]

    # 独自のチェック
    if trigger not in ["FILE.UPLOADED"] or \
            parent["type"] != "folder" or \
            parent["name"] not in ["arai-test-folder"] or \
            source["type"] != "file":
        return {"statusCode": HTTPStatus.BAD_REQUEST}

    # Webhookの検証
    webhook = client.webhook(webhook_id)
    is_valid = webhook.validate_message(
        bytes(raw_body, "utf-8"), event["headers"], webhook_key)
    if not is_valid:
        return {"statusCode": HTTPStatus.BAD_REQUEST}

    # Boxから対象ファイルを取得しS3へ保存
    box_file = client.file(file_id=source["id"]).content()
    response = s3_client.put_object(
        Bucket=BUCKET_NAME,
        Key=source["name"],
        Body=box_file
    )
    if response['ResponseMetadata']['HTTPStatusCode'] != 200:
        raise Exception("S3: failed to upload file...")

    return {"statusCode": HTTPStatus.OK}

def get_box_client():
    """BoxSDKの初期化
    """
    secret = get_secret()
    client_id = secret["boxAppSettings"]["clientID"]
    client_secret = secret["boxAppSettings"]["clientSecret"]
    jwt_key_id = secret["boxAppSettings"]["appAuth"]["publicKeyID"]
    rsa_private_key_data = secret["boxAppSettings"]["appAuth"]["privateKey"]
    rsa_private_key_passphrase = secret["boxAppSettings"]["appAuth"]["passphrase"]
    enterprise_id = secret["enterpriseID"]

    webhook_signature_key = secret["webhookPrimaryKey"]

    auth = JWTAuth(
        client_id=client_id,
        client_secret=client_secret,
        jwt_key_id=jwt_key_id,
        rsa_private_key_data=rsa_private_key_data,
        rsa_private_key_passphrase=rsa_private_key_passphrase,
        enterprise_id=enterprise_id
    )
    auth.authenticate_instance()

    client = Client(auth)
    return client, webhook_signature_key

def get_secret():
    """Secrets Managerからクレデンシャル情報取得
    """
    response = secretsmgr_client.get_secret_value(SecretId=SECRET_NAME)
    if "SecretString" in response:
        secret = response["SecretString"]
        return json.loads(secret)
    else:
        raise Exception("Binary secret not implemented")
