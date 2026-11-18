"""Pipeline tests: run after train.py, from the repository root."""
import hashlib
import json
from pathlib import Path

import pandas as pd
from fastapi.testclient import TestClient

from app import app

CONFIG = json.loads(Path('config.json').read_text())
DATASET = Path('dataset/train.csv')
METRICS = json.loads(Path('artifacts/metrics.json').read_text())
client = TestClient(app)


def test_metrics_file_matches_dataset():
    df = pd.read_csv(DATASET)
    digest = hashlib.sha256(DATASET.read_bytes()).hexdigest()
    assert METRICS['student_id'] == CONFIG['student_id']
    assert METRICS['training_rows'] == len(df)
    assert METRICS['model_version'] == digest[:12]
    assert 0.5 <= METRICS['accuracy'] <= 1.0


def test_metrics_endpoint():
    response = client.get('/metrics')
    assert response.status_code == 200
    body = response.json()
    for key in ['student_id', 'accuracy', 'training_rows', 'model_version', 'git_sha']:
        assert key in body
    assert body == METRICS


def test_predict_endpoint():
    df = pd.read_csv(DATASET)
    records = json.loads(df[CONFIG['features']].head(5).to_json(orient='records'))
    response = client.post('/predict', json={'records': records})
    assert response.status_code == 200
    body = response.json()
    assert len(body['predictions']) == 5
    assert set(body['predictions']) <= {0, 1}
    assert all(0.0 <= p <= 1.0 for p in body['probabilities'])


def test_predict_rejects_empty_batch():
    assert client.post('/predict', json={'records': []}).status_code == 422
