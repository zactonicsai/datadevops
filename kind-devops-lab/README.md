# Build Your Own CI/CD Lab: kind + Jenkins + Gitea + Java & C++ Builds

This project gives you a complete, real "software factory" that runs on one computer.

When you finish, you will have:

- A **Kubernetes cluster** made of Docker containers (created with a tool called **kind**).
- **Gitea** — a free, open-source place to store code and open issues (like Bitbucket or GitHub, but yours).
- **Jenkins** — the robot that watches your code and builds it automatically.
- Two **build agents**: one that knows Java (JDK 21, Maven, Gradle) and one that knows C++ (GCC, Clang, CMake, Ninja, GoogleTest).
- Two **sample apps** (one Java, one C++) that Jenkins builds and tests all by itself.

---

## Part 1 — Do This First (the 15-minute walkthrough)

### What you need before you start

| Thing | Why |
|---|---|
| Docker Desktop or Docker Engine | Everything runs inside Docker |
| 8 GB RAM free (16 GB is comfy) | A Kubernetes cluster plus builds is hungry |
| ~20 GB free disk | Images are big |
| `make`, `git`, `curl` | Used by the helper scripts |

You do **not** need to install kind, kubectl, or helm — there is a "toolbox" container that already has them (see Part 4).

### Step 1: Get the files and look around

```bash
cd kind-devops-lab
ls
```

You should see `docker-compose.yml`, a `Makefile`, and folders named `kind/`, `k8s/`, `agents/`, `samples/`, and `scripts/`.

### Step 2: Build the whole lab with one command

```bash
make up
```

That single command runs four steps in order. Here is what each one does:

1. **`make cluster`** — starts a local image registry, then creates a 3-node Kubernetes cluster with kind.
2. **`make images`** — builds the Java agent image and the C++ agent image, then pushes them to the local registry.
3. **`make deploy`** — installs Gitea and Jenkins inside the cluster.
4. **`make seed`** — creates two Git repositories in Gitea and pushes the sample apps into them.

The first run takes about 10–20 minutes, mostly downloading. Later runs are much faster.

### Step 3: Open the two websites

| Service | Address | Login |
|---|---|---|
| Jenkins | http://localhost:8080 | `admin` / `admin123` |
| Gitea | http://localhost:3000 | `jenkins` / `jenkins123` |
| Registry catalog | http://localhost:5001/v2/_catalog | (no login) |

In Jenkins you will already see two jobs: **java-app** and **cpp-app**. They were created automatically from the file `k8s/jenkins-values.yaml`, not by clicking around.

### Step 4: Run your first build

1. Click **java-app** → **Build Now**.
2. Watch the **Build Executor Status** box on the left. A brand-new pod appears, does the build, and disappears.
3. Click the build number → **Console Output** to watch Maven compile and run the tests.
4. Do the same with **cpp-app**. That one runs CMake, Ninja, and GoogleTest.

To prove it is really working, check the pods from another terminal while a build runs:

```bash
kubectl -n devops get pods
```

You will see something like `java-abc12` or `cpp-xyz34` appear and then vanish. That is Jenkins creating a fresh, clean machine for every single build.

### Step 5: Change some code and watch it rebuild

```bash
git clone http://localhost:3000/jenkins/cpp-app.git
cd cpp-app
# edit src/main.cpp, change the message
git commit -am "change the greeting"
git push
```

Jenkins checks for new commits every 2 minutes, so within a couple of minutes a new build starts on its own.

### Step 6: Clean up when you are done

```bash
make down
```

This deletes the cluster and the registry container. Nothing is left running.

---

## Part 2 — What Each Piece Actually Is

### Docker
Docker packs a program plus everything it needs into an **image**. A running copy of an image is a **container**. Containers start in seconds and behave the same on every computer.

### Docker Compose
A file (`docker-compose.yml`) that describes several containers and how they connect, so you can start them all with one command instead of typing many long `docker run` lines.

### Kubernetes
A "manager" for containers. You tell it *what you want* ("run one Gitea, keep it alive"), and it figures out *how*. Real companies use it to run hundreds of services.

### kind ("Kubernetes IN Docker")
Normally Kubernetes needs several real machines. kind cheats in a clever way: **each Kubernetes node is just a Docker container**. So a whole cluster fits on your laptop, and deleting it is instant.

Look at `kind/cluster.yaml`. Two important parts:

- `nodes:` — one control-plane (the boss) and two workers (where builds run).
- `extraPortMappings:` — this pokes holes so `localhost:8080` on your laptop reaches Jenkins inside the cluster.

### The local registry
Kubernetes pulls images from a registry, not from your laptop's Docker. So we run a tiny registry at `localhost:5001`, and we tell every kind node "when someone asks for `localhost:5001`, go ask the `kind-registry` container." That rule is the `hosts.toml` file written by `scripts/01-cluster.sh`.

### Gitea
An open-source Git server written in Go. It gives you repositories, pull requests, issues, and webhooks, and it is small enough to run in a single pod. It is the free stand-in for Bitbucket or GitHub Enterprise.

### Jenkins
The automation server. A **Jenkinsfile** in your repo describes the build as code:

```groovy
pipeline {
    agent { label 'java' }      // which kind of machine to build on
    stages {
        stage('Build') { steps { sh 'mvn clean compile' } }
    }
}
```

Jenkins reads that file, asks Kubernetes for a matching pod, runs the steps inside it, then throws the pod away.

### Configuration as Code (JCasC)
Instead of clicking through Jenkins setup screens, everything lives in `k8s/jenkins-values.yaml`: the admin user, the plugins, the Gitea connection, the agent types, even the two jobs. If you delete Jenkins and reinstall it, you get the exact same setup back. This is a huge deal in real teams.

---

## Part 3 — The Build Agents

### Java agent (`agents/java/Dockerfile`)
Starts from `jenkins/inbound-agent:latest-jdk21` (which already knows how to phone home to Jenkins) and adds Maven and Gradle.

### C++ agent (`agents/cpp/Dockerfile`)
Same base, then adds:

- `build-essential`, `g++`, `clang` — the compilers
- `cmake` + `ninja-build` — modern build system (Ninja is much faster than plain Make)
- `ccache` — remembers past compiles so rebuilds are quick
- `libgtest-dev` compiled and installed — GoogleTest for unit tests
- `cppcheck`, `clang-tidy`, `lcov` — static analysis and coverage

### How Jenkins knows which one to use
In `k8s/jenkins-values.yaml`:

```yaml
additionalAgents:
  javaBuilder:
    customJenkinsLabels: java     # <- the label you write in the Jenkinsfile
    image:
      repository: localhost:5001/agent-java
```

So `agent { label 'java' }` in a Jenkinsfile means "give me a pod from the Java image."

### Building both languages in one pipeline
If one product has a Java service and a C++ engine, you can build both at the same time:

```groovy
pipeline {
    agent none
    stages {
        stage('Build everything') {
            parallel {
                stage('Java') {
                    agent { label 'java' }
                    steps { sh 'mvn -B clean verify' }
                }
                stage('C++') {
                    agent { label 'cpp' }
                    steps {
                        sh 'cmake -S . -B build -G Ninja && cmake --build build -j $(nproc)'
                    }
                }
            }
        }
    }
}
```

Two pods start at once on two different worker nodes. This is the main reason to run Jenkins on Kubernetes.

---

## Part 4 — Running Everything From the Toolbox Container

If you do not want kind, kubectl, and helm installed on your computer, use the toolbox:

```bash
docker compose --profile tools run --rm toolbox
# now you are inside the container:
make up
```

How it works: the toolbox mounts `/var/run/docker.sock`, which lets it control your computer's Docker. It also joins the `kind` network, so it can talk to the cluster nodes directly. The scripts notice the `IN_TOOLBOX=1` variable and switch from `localhost` to the container names automatically.

**Caveat:** on Docker Desktop for Mac and Windows this mostly works, but running `make up` straight from your terminal is simpler and less surprising. Use the toolbox mainly on Linux or in CI.

---

## Part 5 — Command Cheat Sheet

```bash
make help          # list every command
make up            # build the whole lab
make cluster       # just the kind cluster + registry
make images        # rebuild the two agent images
make deploy        # reinstall/upgrade Gitea + Jenkins
make seed          # recreate the sample repos
make logs          # follow the Jenkins log
make down          # delete everything
```

Useful raw commands:

```bash
kubectl -n devops get pods -w                  # watch pods come and go
kubectl -n devops describe pod <name>          # why is a pod unhappy?
kubectl -n devops logs statefulset/jenkins -c jenkins
kind get clusters
curl http://localhost:5001/v2/_catalog          # what is in the registry
```

---

## Part 6 — When Things Go Wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| Agent pod stuck in `ErrImagePull` | Image never pushed, or the registry rule is missing | `make images`, then re-run `./scripts/01-cluster.sh` |
| Jenkins pod stuck in `Pending` | Not enough CPU/RAM | Give Docker more resources, or lower the `resources` values in `k8s/jenkins-values.yaml` |
| `localhost:8080` shows nothing | Port mapping only exists on the control-plane node | Confirm `extraPortMappings` in `kind/cluster.yaml`, recreate cluster |
| Job cannot clone from Gitea | Wrong URL | Inside the cluster the address is `http://gitea.devops.svc.cluster.local:3000`, **not** `localhost:3000` |
| `make seed` says user exists | You already ran it | Harmless, keep going |
| C++ build cannot find GoogleTest | Agent image is stale | `make images` to rebuild and push again |

---

## Part 7 — Choices You Could Have Made (Pros and Cons)

### Where should Jenkins run?

| Option | Pros | Cons |
|---|---|---|
| **Jenkins in Kubernetes (what we did)** | Fresh pod per build, no leftovers; builds run in parallel across nodes; scales like production | More moving parts to learn |
| Jenkins in plain Docker Compose | Simplest to understand; fewer resources | Agents pile up dirt over time; no easy parallel scaling |
| Jenkins installed directly on a machine | Fastest builds, no container overhead | "Works on my machine" problems; painful to rebuild |

### Which Git server?

| Option | Pros | Cons |
|---|---|---|
| **Gitea (what we used)** | Very light (~200 MB RAM), open source, simple API, GitHub-like UI | Fewer enterprise features |
| GitLab CE | Repos + CI + registry + issues all in one | Wants 4+ GB RAM by itself |
| Forgejo | Community fork of Gitea, same feel | Smaller ecosystem |
| Bitbucket Server | What many companies actually use | Commercial licence, heavy |

### Which C++ build setup?

| Option | Pros | Cons |
|---|---|---|
| **CMake + Ninja (what we used)** | Industry standard, fast, works everywhere | Two tools to learn |
| Plain Make | No extra tools | Hand-written dependency rules break easily |
| Bazel | Excellent caching for huge codebases | Steep learning curve |

### How should Jenkins be configured?

| Option | Pros | Cons |
|---|---|---|
| **Configuration as Code (what we used)** | Reproducible, reviewable, in Git | Errors show up only at startup |
| Clicking in the web UI | Easy to start | Impossible to reproduce; one bad disk and it's gone |

---

## Part 8 — Best Practices Worth Copying

1. **Never store real passwords in YAML.** This lab uses `admin123` because it is a lab. In real life use Kubernetes Secrets plus something like External Secrets or Vault.
2. **Keep the pipeline in the repo.** A `Jenkinsfile` next to the code is reviewed like code and matches the branch being built.
3. **One clean pod per build.** No leftovers from yesterday's build to confuse you.
4. **Pin your versions.** `latest` is convenient for a lab and dangerous in production. Pin image tags, plugin versions, and chart versions.
5. **Publish test results.** The `junit` step turns raw test output into graphs and shows exactly which test broke.
6. **Cache what is safe to cache.** `ccache` for C++ and a shared Maven repo volume make repeat builds dramatically faster.
7. **Set resource requests and limits.** Otherwise one runaway build can starve the whole cluster.
8. **Treat the whole cluster as disposable.** `make down && make up` should always give you a working lab. If it doesn't, something is undocumented.
9. **Use webhooks in production, polling in labs.** Polling every 2 minutes is easy; webhooks (`manageHooks: true` in the Gitea config) are instant and cheaper.

---

## Part 9 — Ideas for Going Further

- Add **SonarQube** for code quality dashboards for both languages.
- Add **Trivy** to scan images for security holes during the pipeline.
- Push finished artifacts to **Nexus** or **Artifactory** instead of just archiving them.
- Add an **NGINX ingress controller** so you get real names like `jenkins.lab.local` instead of ports.
- Turn on **Gitea webhooks** so builds start the instant you push.
- Add a **matrix build** for C++ that compiles with both GCC and Clang, Debug and Release.

---

## File Map

```
kind-devops-lab/
├── docker-compose.yml        # local registry + toolbox container
├── Makefile                  # every command you need
├── .env.example              # settings you can change
├── kind/cluster.yaml         # the 3-node cluster definition
├── docker/toolbox.Dockerfile # kind + kubectl + helm in a box
├── agents/java/Dockerfile    # JDK 21 + Maven + Gradle agent
├── agents/cpp/Dockerfile     # GCC/Clang + CMake + Ninja + GTest agent
├── k8s/namespace.yaml
├── k8s/gitea.yaml            # the Git server
├── k8s/jenkins-values.yaml   # Jenkins + agents + jobs, all as code
├── scripts/                  # the four numbered setup steps + teardown
└── samples/
    ├── java-app/             # Maven app, JUnit tests, Jenkinsfile
    └── cpp-app/              # CMake app, GoogleTest tests, Jenkinsfile
```
