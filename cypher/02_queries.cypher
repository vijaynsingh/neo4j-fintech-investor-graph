// ============================================================
// FinTech Investor Behavior Analysis — Analytical Queries
// Runs against the graph loaded by 01_load.cypher
// ============================================================

// ------------------------------------------------------------
// Q1 — List all customers who purchased Microsoft stock
// Matching on company name (how a business user asks the
// question); ticker + company returned as proof. DISTINCT
// guards against multi-account / multi-purchase path duplicates.
// ------------------------------------------------------------
MATCH (c:Customer)-[:OWNS]->(:Account)-[:PURCHASED]->(s:Stock)
WHERE s.company CONTAINS 'Microsoft'
RETURN DISTINCT c.name AS customer, s.ticker AS ticker, s.company AS company;

// ------------------------------------------------------------
// Q2 — Find the city whose residents bought the most shares
// The City-as-node modeling decision pays off: the traversal
// reads exactly like the question. Full ranking returned;
// row 1 is the answer.
// ------------------------------------------------------------
MATCH (ci:City)<-[:LIVES_IN]-(:Customer)-[:OWNS]->(:Account)-[p:PURCHASED]->(:Stock)
RETURN ci.name AS city, sum(p.number_of_shares) AS total_shares
ORDER BY total_shares DESC;

// ============================================================
// Open-ended queries — laddering up to the customer scenario:
// "identify clusters of investor behavior across cities"
// ============================================================

// ------------------------------------------------------------
// IQ1 — Portfolio overlap: which customers invest alike?
// Two entities connected through shared neighbors — painful as
// SQL self-joins, natural as a graph pattern. c1.name < c2.name
// deduplicates symmetric pairs. At production scale this exact
// pattern feeds GDS node-similarity + community detection
// (e.g. Louvain) — that IS the requested investor clustering.
// ------------------------------------------------------------
MATCH (c1:Customer)-[:OWNS]->()-[:PURCHASED]->(s:Stock)
      <-[:PURCHASED]-()<-[:OWNS]-(c2:Customer)
WHERE c1.name < c2.name
RETURN c1.name AS customer_a, c2.name AS customer_b,
       collect(DISTINCT s.ticker) AS shared_stocks,
       count(DISTINCT s) AS overlap
ORDER BY overlap DESC;

// ------------------------------------------------------------
// IQ2 — City investment profiles by value (£), not share volume
// Q2 ranked by share count because that's what was asked; this
// ranks by what the shares are worth. Sums kept exact (no
// rounding) — financial context.
// ------------------------------------------------------------
MATCH (ci:City)<-[:LIVES_IN]-(:Customer)-[:OWNS]->()-[p:PURCHASED]->(s:Stock)
RETURN ci.name AS city,
       sum(p.number_of_shares * p.price_per_share) AS total_invested,
       count(p) AS purchases,
       collect(DISTINCT s.ticker) AS portfolio
ORDER BY total_invested DESC;

// ------------------------------------------------------------
// IQ3 — Account-type (tax wrapper) purchasing behavior
// gia / isa / sipp imply different investor intents. Sums exact;
// averages displayed at currency precision (2 dp).
// ------------------------------------------------------------
MATCH (a:Account)-[p:PURCHASED]->(s:Stock)
RETURN a.account_type AS wrapper,
       count(p) AS purchases,
       sum(p.number_of_shares * p.price_per_share) AS total_value,
       round(avg(p.number_of_shares * p.price_per_share), 2) AS avg_purchase_size
ORDER BY total_value DESC;

// ------------------------------------------------------------
// IQ4 — Co-purchase pairs: stocks bought by the same investors
// IQ1 from the stock's point of view — "customers who bought X
// also bought Y", the seed of a recommendation engine.
// ------------------------------------------------------------
MATCH (s1:Stock)<-[:PURCHASED]-()<-[:OWNS]-(c:Customer)
      -[:OWNS]->()-[:PURCHASED]->(s2:Stock)
WHERE s1.ticker < s2.ticker
RETURN s1.ticker AS stock_a, s2.ticker AS stock_b,
       count(DISTINCT c) AS shared_investors
ORDER BY shared_investors DESC
LIMIT 5;
