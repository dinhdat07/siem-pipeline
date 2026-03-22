# Setup Sample Data

This guide provides instructions on how to generate a smaller, manageable sample dataset for local development and testing.

---

## Requirements

The following environment and dependencies are required to run the parsing scripts:

* **Python:** Version `3.10` or higher.
* **Dependencies:** Install the required progress bar library using pip:
    ```bash
    pip install tqdm
    ```

---

## Input Data Configuration

Before running the scripts, ensure your raw datasets are placed in the following directory structure:

```text
input/
├── snort-alert/
│   └── alert.full.maccdc2012_*.pcap
└── zeek/
    └── conn.log
```

### Data Source Links
* **Zeek Connection Log:** [Download conn.log.zip](https://www.secrepo.com/Security-Data-Analysis/Lab_1/conn.log.zip)
* **Snort Alert Logs:** [Download maccdc2012_full_alert.7z](https://www.secrepo.com/maccdc2012/maccdc2012_full_alert.7z)

> **Important Technical Notes:**
> * **File Format:** Files named `alert.full.*.pcap` in this dataset are Snort alert logs in text format, **not** binary PCAP network captures.
> * **Preparation:** After downloading `maccdc2012_full_alert.7z`, unzip the contents and move the alert files into the `input/snort-alert/` directory.

---

## Generating Samples (10k Records)

To optimize development speed, use the following commands to extract the first 10,000 records from the raw logs.

### 1. Zeek Logs Processing
Run the script to parse and convert Zeek connection logs:
```bash
python ./scripts/parse-conn.py --limit 10000
```
* **Output Path:** `output/conn-logs/zeek_conn-sample.jsonl`

### 2. Snort Alerts Processing
Run the script to parse and normalize Snort alert logs:
```bash
python ./scripts/parse-snort.py --limit 10000
```
* **Output Path:** `output/snort-alerts/snort_alerts_sample.jsonl`

---

## Output Format Specification

The generated files adhere to the following standards:

* **Format:** JSON Lines (`.jsonl`)
* **Structure:** Each individual event is represented as a single JSON object per line.
* **Integration:** These files are pre-formatted for seamless ingestion into **Elasticsearch** or **OpenSearch**.

---

## Development Notes

* **Efficiency:** Always use the `--limit` flag during initial development to reduce processing time and resource consumption.
* **Workflow:** Validate your logic with small samples (10k records) before attempting to process the entire multi-gigabyte dataset.
* **Storage Management:** If disk space is a concern, output files can be compressed using `gzip` without breaking compatibility with most modern data ingestion pipelines.
* **Version Control:** It is recommended to add the `input/` folder to your `.gitignore` to prevent uploading large raw data files to your repository.

