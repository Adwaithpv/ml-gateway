FROM python:3.11-slim

LABEL maintainer="ml-gateway" \
      service="large" \
      description="LinearSVC + TF-IDF spam classifier (calibrated)"

WORKDIR /app

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code, training script, and trained model
COPY app.py .
COPY train.py .
COPY model.pkl .

# Copy training dataset (placed in context during build)
COPY spam.csv /data/spam.csv

EXPOSE 8003

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8003"]
