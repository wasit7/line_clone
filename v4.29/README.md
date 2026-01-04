# 🧊 LINE Clone v4.30 - Platinum Data Lake Edition

**A "Zero-DB" architecture engineered for infinite retention and massive scale.**

Version 4.30 represents a paradigm shift from a traditional web application to a **Data Lakehouse Architecture**. Instead of relying on a monolithic database for history, it utilizes a tiered storage model (Redis → Postgres → Parquet/S3) and moves the compute layer to the client using **DuckDB-Wasm**. This allows for the storage of millions of messages at a fraction of the cost of a relational database, with analytics performed directly in the user's browser.

---

## ✨ Key Features

### 🏗️ Data Lakehouse Architecture

* **Tiered Storage Model:**
* **Hot (Redis):** Real-time Pub/Sub for active conversations.
* **Warm (PostgreSQL):** A temporary buffer holding only the last ~1-5 minutes of data.
* **Cold (MinIO/S3):** The "Source of Truth." Infinite history stored as highly compressed **Parquet** files using **Hive Partitioning** (`/year=Y/month=M/...`).


* **Write-Purge Cycle:** A background Archiver continuously moves data from Postgres to MinIO and deletes it from the DB to keep the relational footprint tiny.

### 🧠 Smart Client (Browser-Side SQL)

* **DuckDB-Wasm Integration:** The browser runs a full SQL engine inside a Web Worker.
* **Virtual File System:** The frontend mounts remote Parquet files as a virtual filesystem and queries them using SQL (`SELECT * FROM read_parquet(...)`).
* **Filter Pushdown:** Queries only fetch the specific partitions needed (e.g., "last 24 hours"), significantly reducing data transfer.

### 🔒 Enterprise Security

* **Streaming Proxy:** Direct access to MinIO is blocked. All data access goes through a Django Proxy View (`/api/download/?key=...`) which enforces authentication.
* **Air-Gapped Build:** Assets (DuckDB, Fonts, Tailwind) are pre-bundled in the Docker build, removing runtime dependencies on CDNs.

---

## 🏗️ System Architecture

The data flows through three distinct stages to ensure both speed and durability:

1. **Ingestion (Hot/Warm):**
* User sends message via WebSocket.
* Saved to **PostgreSQL** (Warm) for immediate durability.
* Broadcast via **Redis** to active listeners.


2. **Archival (ETL):**
* The `worker` service runs `run_archiver.py`.
* It selects messages older than 1 minute, converts them to a Pandas DataFrame, and writes them to **MinIO** in Parquet format using Hive partitioning.
* **Crucial Step:** The messages are then **DELETED** from PostgreSQL.


3. **Retrieval (Cold):**
* Client requests the "Archive Index" (list of file keys).
* Client registers these keys in DuckDB-Wasm.
* Client executes SQL queries to fetch and render history on demand.



---

## 🛠️ Installation & Setup

### Prerequisites

* Docker & Docker Compose

### Quick Start

1. **Generate the Project Files:**
Run the setup script to generate the code and containers.
```bash
bash setup_v4_29.sh

```


2. **Launch the Stack:**
Build and start the services. This may take a few minutes to compile the DuckDB assets.
```bash
cd line_clone_v4_lake
docker-compose up -d --build

```


3. **Access the Application:**
* Open `https://localhost` in your browser.
* **Login:** `admin` / `password`
* *Note: On first load, wait for the "DuckDB Ready" status in the top bar.*



---

## 🧪 1 Million Message Stress Test

This version includes a rigorous stress test designed to prove the durability of the Lakehouse architecture.

### What it does:

1. Injects **1,000,000 messages** into the system.
2. Backfills timestamps to simulate data spanning the last 24 hours.
3. Waits for the Archiver to drain the Database after every 10,000 messages.
4. Downloads the Parquet files from MinIO and verifies the row count matches exactly.

### How to Run:

```bash
# Ensure the stack is running first
bash test_v4_30.sh

```

**Expected Output:**

```text
🚀 Starting 1 Million Message Injection...
...
✅ Batch 100 Complete. Total: 1000000
🏆 SUCCESS: 1000000 messages successfully archived and verified.

```

---

## 📂 Project Structure

```
line_clone_v4_lake/
├── app/
│   ├── chat_app/
│   │   ├── management/commands/
│   │   │   ├── run_archiver.py    # The ETL Worker (PG -> S3)
│   │   │   └── init_minio.py      # Bucket setup
│   │   ├── views.py               # Includes proxy_parquet view
│   │   └── ...
│   ├── templates/
│   │   └── room.html              # DuckDB-Wasm Client Logic
│   └── Dockerfile                 # Multi-stage build for Wasm assets
├── docker-compose.yml             # Includes MinIO & Worker
└── ...

```

---

## ⚠️ Notes & Limitations

* **Complexity:** This architecture is complex. Debugging requires understanding WebAssembly, SQL, and Async Workers.
* **Latency:** Fetching cold history is slower than a database query because it involves downloading file headers and compiling WASM. It is optimized for bandwidth and cost, not sub-millisecond retrieval.
* **Browser Requirements:** Requires a modern browser with WebAssembly support.

---

## 📜 License

Open Source - Educational Purpose Only.