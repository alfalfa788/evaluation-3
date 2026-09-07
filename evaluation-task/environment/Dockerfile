# If you need to use a different base image, please choose the linux/amd64 platform variant and include the fingerprint so that we pin the exact image.
FROM ubuntu:24.04@sha256:c35e29c9450151419d9448b0fd75374fec4fff364a27f176fb458d472dfc9e54
ENV DEBIAN_FRONTEND=noninteractive

# These are support tools that should go into all tasks. Don't alter these unless you need to adjust for a different base image.
RUN apt-get update && apt-get install -y git python3 python3-pip bash curl wget && rm -rf /var/lib/apt/lists/*
RUN ln -sf /usr/bin/python3 /usr/bin/python
RUN mkdir -p /logs
RUN apt-get update && apt-get install -y python3-venv python3-dev && rm -rf /var/lib/apt/lists/*
ENV PIP_BREAK_SYSTEM_PACKAGES=1

# The WORKDIR should always be /app
WORKDIR /app

# --- Task-specific system packages go here, merged into one apt line, e.g.:
# RUN apt-get update && apt-get install -y gcc && rm -rf /var/lib/apt/lists/*

# --- When you add a real codebase with a requirements.txt, uncomment:
# COPY codebase/requirements.txt .
# RUN pip install --no-cache-dir -r requirements.txt

# Copies the codebase contents of the task into the working folder in the container
COPY codebase/ .

# --- Alternative to `COPY codebase/`: if the starting state is a PUBLIC GitHub
#     repo, shallow-clone it here instead. Comment out the COPY line above and
#     uncomment ONE line below. Pin to a tag or commit for reproducibility.
#     The `&& rm -rf .git` drops the upstream history so the
#     checkpoint below re-inits from a clean baseline.
#   # by tag or branch:
# RUN git clone --depth 1 --branch <tag-or-branch> https://github.com/<org>/<repo>.git . && rm -rf .git
#   # by exact commit SHA:
# RUN git init && git remote add origin https://github.com/<org>/<repo>.git && git fetch --depth 1 origin <commit-sha> && git checkout FETCH_HEAD && rm -rf .git


# Inject the build-artifact .gitignore so those files stay out of the captured
# patch.diff.
COPY gitignore /tmp/harbor.gitignore
RUN cat /tmp/harbor.gitignore >> .gitignore && rm /tmp/harbor.gitignore

# Checkpoint the starting state as tag v0.1.0-init (test.sh diffs against it).
# Steps are ';'-separated (the commit may no-op) so the tag lands whether or not
# git was already initialized and whether or not the tree has uncommitted changes.
RUN git config --global user.email "eval@bench"; \
    git config --global user.name "Eval Runner"; \
    git init; \
    git add -A; \
    git commit -m "initialize repo" || true; \
    git tag v0.1.0-init
CMD ["bash"]
