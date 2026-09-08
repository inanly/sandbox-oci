ARG BASE_IMAGE=python:3.12-slim
FROM ${BASE_IMAGE}

WORKDIR /workspace

RUN mkdir -p /workspace/dir-delete \
    && printf 'old\n' > /workspace/modify.txt \
    && printf 'old\n' > /workspace/delete.txt \
    && printf 'old\n' > /workspace/dir-delete/child.txt \
    && printf '#!/bin/sh\necho fixture\n' > /workspace/run.sh \
    && chmod 0755 /workspace/run.sh \
    && ln -s modify.txt /workspace/base-link

COPY tests/mutate.py tests/verify.py /opt/fixture/

CMD ["python3", "-c", "import time; time.sleep(86400)"]
