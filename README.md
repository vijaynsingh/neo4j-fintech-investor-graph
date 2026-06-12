# FinTech Investor Behavior Analysis with Neo4j

*Vijay Singh · June 2026*

## Scenario

A FinTech customer wants to use graph technology to analyze client investment
data and identify clusters of investor behavior across cities. This repository
contains the complete solution: graph model, data loading pipeline, analytical
queries, and a proposed production architecture.

**Environment:** Neo4j AuraDB Free

---

## 1. Graph Model

![Graph model](images/part1/01_graph_model_design.png)

```
(Customer)-[:LIVES_IN]->(City)
(Customer)-[:OWNS]->(Account {account_type})
(Account)-[:PURCHASED {purchase_id, number_of_shares, purchase_date, price_per_share}]->(Stock)
```

Full schema reference — all labels, properties, and types in one place:

![Schema reference](images/graph_model_schema.png)

### Key modeling decisions

**City is a node, not a property.** The customer's core question — investor
behavior clusters *across cities* — makes City a first-class entity. As a node,
city-level traversals and aggregations are direct; as a string property they
would require repeated scans and grouping.

**PURCHASED is a relationship, not a node.** A purchase currently connects
exactly two entities (an account and a stock) and carries scalar facts. A
relationship is the most compact and traversal-efficient representation. If
purchases later need their own connections — to brokers, orders, settlements,
or to other purchases (e.g., wash-trade detection) — the model evolves by
promoting Purchase to a node. We model for known access patterns, not
hypothetical ones.

**Source denormalization resolved naturally.** `accounts.csv` repeats customer
name and address on every row. In the graph, those attributes live once, on
the Customer node — the graph model normalizes by construction.

---

## 2. Loading the Data: Two Approaches, One Lesson

Choosing a loading technique is itself a design decision worth explaining. I
evaluated both
of Neo4j's primary loading paths against the same model — and the comparison
surfaced a data-quality story worth telling.

### Approach A — Data Importer (visual, workshop-speed)

The Aura Data Importer is the fastest path from CSV to graph: drag files in,
draw the model, map columns, run. The reasonable mapping choices:

![Mapping](images/part1/02_purchase_date_mapped_as_datetime.png)

For clean, well-keyed node data it performed flawlessly — all customers,
cities, and stocks loaded correctly:

![Nodes loaded](images/part1/03_import_success_nodes_created.png)

### The import reported success. The data tells a different story.

![24 rows in, 23 relationships out](images/part1/04_success_banner_24_rows_23_relationships.png)

The success dialog itself records the discrepancy: **24 file rows,
23 relationships created.** Verified independently:

![Count confirms 23](images/part1/05_count_confirms_23.png)

**Root cause #1 — missing purchase identity.** Two purchases on account
`123458` (ticker JPM, same date, different share counts) are indistinguishable
without a unique key, so the importer collapsed them into one relationship.
One purchase silently vanished.

**Root cause #2 — ambiguous date format.** Source dates are `DD/MM/YYYY`. The
importer assumed `MM/DD`:

![Date autopsy](images/part1/06_date_autopsy_zero_correct.png)

Of 23 loaded purchases: **6 dates silently converted to the wrong date**
(`12/02/2017` → December 2nd instead of February 12th), **17 dates silently
dropped to null** (day > 12 cannot be a month), **0 dates correct**. The same
column produced two different failure modes with no error raised — the hardest
kind of corruption to detect downstream. In a financial context, purchase
dates shifted or missing is a compliance incident.

> The importer is excellent for clean, well-keyed, unambiguous data — the
> workshop scenario. The moment data has identity gaps or format ambiguity,
> you need explicit, scripted transformation. Knowing which situation you're
> in is the job.

### Approach B — Scripted `LOAD CSV` (explicit, repeatable, production-grade)

See [`cypher/01_load.cypher`](cypher/01_load.cypher). The script:

1. **Creates uniqueness constraints first** — identity enforcement plus
   index-backed lookups during load.
2. **Loads in dependency order** — reference data (Stock), then Customer +
   City, then Account, then PURCHASED.
3. **Merges purchases on a generated surrogate key** (`linenumber()`) — the
   source CSVs remain completely unmodified, so both loading approaches were
   tested against identical input. Same data, different engineering: the
   importer produced 23 relationships with 0 correct dates; the script
   produced 24 with 24.
4. **Parses dates explicitly** — `DD/MM/YYYY` decomposed and rebuilt as a
   native `Date` (no timezone artifacts, full date arithmetic in queries).
5. **Ends with verification queries** — node counts, relationship counts, and
   a spot-check of the duplicate that started the investigation.

**Result: 24/24 purchases, 24/24 correct dates.**

The full script executed cleanly end to end:

![Script run](images/part2/01_script_run_all_green.png)

All 24 purchase relationships present — source row count and graph
relationship count reconcile exactly:

![24 purchases](images/part2/02_all_24_purchases_loaded.png)

Every purchase date parsed correctly as a native `Date` — eight distinct
values spanning 2017–2023, zero nulls, zero timezone artifacts (compare with
the importer's result above):

![Clean dates](images/part2/03_all_dates_correct.png)

And the purchase the importer silently collapsed is back — both JPM purchases
on account `123458`, distinguished by their surrogate keys:

![Duplicate recovered](images/part2/04_duplicate_purchase_recovered.png)

### Recommendation to the customer

The tactical fix (surrogate keys, explicit parsing) lives in the load script.
The durable fix lives in the **data contract**: source systems should emit a
unique purchase identifier and ISO-8601 dates (`YYYY-MM-DD`). Load tooling
should never have to guess.

---

## 3. Analytical Queries

All queries in [`cypher/02_queries.cypher`](cypher/02_queries.cypher).

### Required query 1 — customers who purchased Microsoft stock

![Q1](images/part3/01_q1_microsoft_buyers.png)

Three customers: **Adam Hunter, Blaze Fielding, Axel Stone**. The query
matches on `company CONTAINS 'Microsoft'` — the question as a business user
asks it — and returns the ticker as proof. `DISTINCT` matters: graph queries
return paths, and a customer buying through multiple accounts would otherwise
appear once per path.

### Required query 2 — city whose residents bought the most shares

![Q2](images/part3/02_q2_top_city_by_shares.png)

**London (7,180 shares)**, with Hatfield close behind (4,790). This is where
the City-as-node decision pays off — the traversal reads exactly like the
question, with no join gymnastics:

```
(City)<-[:LIVES_IN]-(Customer)-[:OWNS]->(Account)-[:PURCHASED]->(Stock)
```

### Beyond the brief: investigating the actual scenario

The customer's stated goal is *clusters of investor behavior across cities* —
so the open-ended queries each probe one axis of that question.

**IQ1 — Portfolio overlap.** Which customers invest alike?

![IQ1](images/part3/03_iq1_portfolio_overlap.png)

The result is not a gradient but a cliff: **Axel Stone and Blaze Fielding
share six holdings** (DEO, GOOG, JPM, KO, NKE, MSFT) while every other pair
overlaps on exactly one. The four investors split into a tightly-coupled pair
plus two satellites. This shared-neighbor pattern is awkward in SQL
(self-joins across three tables) and a one-liner in Cypher — and at production
scale it is precisely what feeds GDS node-similarity and community detection
(Louvain), which is the requested clustering, formalized.

**IQ2 — City investment profiles by value.** Share counts mislead — 100
shares of a £400 stock is not 100 shares of a £40 stock.

![IQ2](images/part3/04_iq2_city_value_profiles.png)

London leads in £ terms too (£1.76M), but the portfolios reveal the real
finding: **the behavioral twins live in different cities** — Blaze (Costco
buyer) in London, Axel (Apple buyer) in Hatfield. The two city portfolios are
near-identical *because* one member of the pair lives in each.
**Behavioral clusters cross city lines: similarity follows investors, not
geography.** The customer asked for clusters across cities; the graph answers
that geography is not the clustering dimension in this data.

**IQ3 — Tax-wrapper behavior.** A third segmentation axis.

![IQ3](images/part3/05_iq3_wrapper_behavior.png)

GIA accounts are the most active (12 purchases) but **ISA accounts write the
largest average ticket (£201k)** — tax-sheltered accounts here carry the
biggest individual commitments, while SIPPs (retirement) hold the smallest
(£64k). Note the floating-point artifact in the GIA total
(`…0.5999999999`): float arithmetic on money. In production, monetary values
should be stored as integer pence.

**IQ4 — Co-purchase pairs.** The recommendation-engine view.

![IQ4](images/part3/06_iq4_copurchase_pairs.png)

Every top pair (DEO–MSFT, DEO–GOOG, …) has exactly two shared investors — and
they are always the same two. The product-affinity signal in this dataset is
entirely generated by the behavioral pair found in IQ1: the same cluster, seen
from the stocks' side. "Customers who bought X also bought Y" is this exact
query at scale.

### Production path

These Cypher patterns are the manual versions of what the Graph Data Science
library industrializes: project the customer–stock graph, run node similarity
to weight customer pairs, run Louvain/Leiden for community detection, and
write cluster IDs back to Customer nodes — queryable alongside city, wrapper,
and portfolio for the full behavioral segmentation the customer described.

---

## 4. Proposed Solution Architecture

Source diagram: [`architecture/solution_architecture.drawio`](architecture/solution_architecture.drawio)

I frame every customer architecture as **two proofs of concept**: the *functional*
POC — does the graph answer the investor-clustering question (proven in §2–§3) —
and the *non-functional* POC — does the solution fit the customer's landscape:
cloud, resilience, integration, security, operations. This section is the
non-functional POC.

### Primary architecture — Neo4j AuraDB Enterprise on AWS

![Primary architecture](architecture/primary_architecture.png)

| Requirement | Decision | Rationale |
|---|---|---|
| Cloud deployment | **AuraDB Enterprise on AWS** | Managed service; fault tolerance, backups, and upgrades are product properties, not projects. Capacity-sized (RAM) against data volume and concurrency. |
| Fault tolerance | **Multi-AZ HA built into Aura** | Availability is delegated to the platform; RPO/RTO covered by automated backups. |
| Dedicated UI | **React + Neo4j driver (via API tier)**, plus **NeoDash** for analyst dashboards and **Bloom** for visual exploration | Custom product UI where needed; NeoDash delivers analyst value in days, not months; Bloom lets business users *see* the clusters. |
| Data platform integration | **Spark Connector** (batch ETL) · **Kafka Connector** (streaming purchase events) · **Snowflake via Virtual Graph** (zero-copy querying) | Three integration modes matched to three data temperatures. Virtual Graph lets the customer query Snowflake *as a graph* with no data movement — the lowest-friction adoption path. |
| Monitoring | **Aura metrics exported to Prometheus/Grafana**, query log analysis, alerting | Same observability stack the customer already runs for the app tier. |
| Security | **SSO/SAML · role-based + schema-based access control · traversal restrictions · private endpoints/VPC peering · encryption in transit & at rest** | Traversal restrictions deserve emphasis in FinTech: an advisor's role can be confined to their own clients' subgraph — they cannot traverse beyond it. Access control expressed in the same language as the data model. |

**The scaling principle behind the design:** the application tier (FastAPI on
EKS) is stateless and autoscales freely; the graph tier is stateful and scales
*deliberately*. Architectures that treat a database like a stateless workload
get burned — the tiers are different animals, and this design keeps them
separated by an API boundary so each can be operated according to its nature.

**AI layer (extension):** the investor graph doubles as a grounding layer for
LLM tooling — GraphRAG retrieval and an MCP server give analyst copilots
explainable, citation-backed answers traceable to graph paths. This pattern is
implemented in a companion reference project
([neo4j-insurance-graphrag](https://github.com/vijaynsingh/neo4j-insurance-graphrag)).

### Alternative — self-managed Neo4j Enterprise cluster on Kubernetes (EKS)

![Alternative architecture](architecture/alternative_architecture.png)

Deployed via Neo4j Helm charts / operator: **three primary servers** forming a
Raft consensus group (writes; survives loss of one primary) plus **secondary
servers** for read scaling and analytics/GDS workloads. EBS persistent volumes,
pod anti-affinity across availability zones, scheduled backups to S3.

**When this path wins:** data sovereignty mandates, air-gapped or strictly
regulated environments, an existing Kubernetes platform team, fine-grained cost
control at large scale.

**What it costs:** operational ownership — upgrades, backup discipline,
topology management, monitoring, hardening. A critical operational note:
**Neo4j cluster members have roles** (primaries vs secondaries) — this is not a
fleet of identical, interchangeable nodes, and elastic-autoscaling assumptions
that hold for stateless services do not apply. Organizations without K8s
operational depth should engage professional services for the initial
deployment rather than learning on a production database.

### Decision summary

Aura is the default because the customer's goal is investor insight, not
database operations. The self-managed path exists for the constraints regulated
customers genuinely have — and the choice between them is a **constraint
conversation, not a preference**. Both share the same application tier, the
same integrations, and the same security model; only the graph tier's operating
model changes.

---

## Repository Contents

| File | Purpose |
|---|---|
| `data/*.csv` | Source data — **unmodified**, exactly as provided |
| `cypher/01_load.cypher` | Production load script with constraints + verification |
| `cypher/02_queries.cypher` | Analytical queries: required + behavioral-clustering set |
| `images/part1/` | Loading investigation evidence |
| `images/part2/` | Script verification evidence |
| `images/part3/` | Query results |
| `architecture/` | Solution architecture diagram (draw.io source + PNG exports) |
| `README.md` | This document |
