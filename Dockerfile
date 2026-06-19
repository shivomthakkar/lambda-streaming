FROM --platform=linux/amd64 public.ecr.aws/awsguru/aws-lambda-adapter:0.9.1 AS lambda-adapter
FROM --platform=linux/amd64 public.ecr.aws/docker/library/python:3.9-slim

COPY --from=lambda-adapter /lambda-adapter /opt/extensions/lambda-adapter

WORKDIR /var/task

ENV PIP_DEFAULT_TIMEOUT=120

COPY requirements.txt .
RUN pip install --no-cache-dir \
	--retries 20 \
	--trusted-host pypi.org \
	--trusted-host files.pythonhosted.org \
	--trusted-host pypi.python.org \
	-r requirements.txt
RUN pip install --no-cache-dir \
	--retries 20 \
	--trusted-host pypi.org \
	--trusted-host files.pythonhosted.org \
	--trusted-host pypi.python.org \
	awscli
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

COPY . .

RUN find /var/task -type d -exec chmod 755 {} \; \
	&& find /var/task -type f -name "*.py" -exec chmod 644 {} \; \
	&& chmod +x /var/task/entrypoint.sh

ENV PORT=8080
ENV AWS_LAMBDA_RESPONSE_STREAMING=1
ENV PYTHONUNBUFFERED=1

CMD ["/var/task/entrypoint.sh"]
