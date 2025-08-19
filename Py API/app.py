import os, time, uuid, boto3, json, decimal
from typing import Any, Dict, Optional
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import JSONResponse



AWS_REGION = os.getenv("AWS_REGION", "us-east-2")
DDB_TABLE  = os.getenv("DDB_TABLE_NAME", "iot")



dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
table    = dynamodb.Table(DDB_TABLE)



app = FastAPI(title="IoT Rule Receiver")



@app.get("/metrics")
async def healthz():
    return {"status": "ok"}




@app.post("/ingest")
async def ingest(request: Request):

    try:
        body_json: Optional[Dict[str, Any]] = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Body must be JSON")

    cid = str(uuid.uuid4())

    current_time_struct = time.localtime(time.time())
    formatted_time = time.strftime("%Y-%m-%d %H:%M:%S", current_time_struct)


    print('User ID : ' + cid)
    print('Time : ' + formatted_time)
    print('Path : ' + request.url.path)

    keys_to_check = ['deviceId', 'temperature']


    if body_json is not None:
        if list(json.loads(json.dumps(body_json)).keys()) == keys_to_check:
            item_data = {
                'deviceId': str(dict(json.loads(json.dumps(body_json)))['deviceId']),
                'temperature': dict(json.loads(json.dumps(body_json)))['temperature'],
                'Time': formatted_time
            }
            print(item_data)

            try:
                table.put_item(Item=item_data)
            except Exception as e:
                raise HTTPException(status_code=500, detail=f"Failed to write to DynamoDB: {e}")

            return JSONResponse({"ok": True, "id": cid, "stored_at": formatted_time})
        else:
            print('Invalid data is received')
    else:
        print('Invalid data is received')