FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN groupadd --system app && useradd --system --gid app --create-home app

WORKDIR /opt/banking-demo

COPY app/requirements.lock ./requirements.lock
RUN python -m pip install --no-cache-dir --upgrade pip \
    && python -m pip install --no-cache-dir -r requirements.lock \
    && python -m pip check

COPY app/app.py app/experiment.py app/pod_network_smoke.py app/chainlit.md ./
COPY app/src ./src
COPY app/.chainlit ./.chainlit
COPY app/public ./public
COPY app/images ./images
COPY app/dataset.json app/dataset-test.json ./

RUN chown -R app:app /opt/banking-demo
USER app

EXPOSE 8000

CMD ["chainlit", "run", "app.py", "-h", "--host", "0.0.0.0", "--port", "8000"]
