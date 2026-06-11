// ============================================================
// FinTech Investor Behavior Analysis — Production Load Script
// Model: (Customer)-[:LIVES_IN]->(City)
//        (Customer)-[:OWNS]->(Account)
//        (Account)-[:PURCHASED {purchase_id,...}]->(Stock)
//
// Data source: https://github.com/vijaynsingh/neo4j-fintech-investor-graph
// ============================================================

// ---- 1. Constraints first (identity + index, before any data) ----
CREATE CONSTRAINT customer_id IF NOT EXISTS
FOR (c:Customer) REQUIRE c.customer_id IS UNIQUE;

CREATE CONSTRAINT account_id IF NOT EXISTS
FOR (a:Account) REQUIRE a.account_id IS UNIQUE;

CREATE CONSTRAINT stock_ticker IF NOT EXISTS
FOR (s:Stock) REQUIRE s.ticker IS UNIQUE;

CREATE CONSTRAINT city_name IF NOT EXISTS
FOR (ci:City) REQUIRE ci.name IS UNIQUE;

// ---- 2. Stocks (reference data first) ----
LOAD CSV WITH HEADERS FROM 'https://raw.githubusercontent.com/vijaynsingh/neo4j-fintech-investor-graph/main/data/stock_ticker.csv' AS row
MERGE (s:Stock {ticker: trim(row.ticker)})
SET s.company = trim(row.holding_company);

// ---- 3. Customers + Cities ----
// City promoted to a node: enables the "clusters across cities"
// analysis the scenario asks for. Region kept as a City property.
LOAD CSV WITH HEADERS FROM 'https://raw.githubusercontent.com/vijaynsingh/neo4j-fintech-investor-graph/main/data/customers.csv' AS row
MERGE (c:Customer {customer_id: trim(row.customer_id)})
SET c.name     = trim(row.owner_name),
    c.address  = trim(row.address),
    c.postcode = trim(row.postcode)
MERGE (ci:City {name: trim(row.city)})
SET ci.region = trim(row.region)
MERGE (c)-[:LIVES_IN]->(ci);

// ---- 4. Accounts ----
// Note: accounts.csv repeats customer name/address — denormalized
// source data. In the graph those attributes live once, on Customer,
// so we deliberately ignore the duplicated columns here.
LOAD CSV WITH HEADERS FROM 'https://raw.githubusercontent.com/vijaynsingh/neo4j-fintech-investor-graph/main/data/accounts.csv' AS row
MATCH (c:Customer {customer_id: trim(row.customer_id)})
MERGE (a:Account {account_id: trim(row.account_id)})
SET a.account_type = trim(row.account_type)
MERGE (c)-[:OWNS]->(a);

// ---- 5. Purchases ----
// Source data has no purchase identity column, so two otherwise-identical
// purchases would collapse under a naive MERGE (this is exactly what the
// Data Importer did: 24 rows -> 23 relationships). We generate a surrogate
// key from the CSV line number. The source files remain UNMODIFIED — the
// script handles the messy data as-is.
// Caveat: linenumber() keys are positional; if the file is ever reordered,
// re-runs would mismatch. The durable fix is a real purchase ID emitted by
// the source system (see data-contract recommendation).
// Dates arrive as DD/MM/YYYY — parsed explicitly into a native Date type.
LOAD CSV WITH HEADERS FROM 'https://raw.githubusercontent.com/vijaynsingh/neo4j-fintech-investor-graph/main/data/account_purchases.csv' AS row
MATCH (a:Account {account_id: trim(row.account_id)})
MATCH (s:Stock {ticker: trim(row.ticker)})
MERGE (a)-[p:PURCHASED {purchase_id: linenumber() - 1}]->(s)
SET p.number_of_shares = toInteger(row.number_of_shares),
    p.price_per_share = toFloat(row.price_per_share),
    p.purchase_date = date({
        day:   toInteger(split(row.purchase_date,'/')[0]),
        month: toInteger(split(row.purchase_date,'/')[1]),
        year:  toInteger(split(row.purchase_date,'/')[2])
    });

// ============================================================
// VERIFICATION — "row counts are a contract"
// ============================================================

// Expect: Customer 4, City 4, Account 8, Stock 36
MATCH (n) RETURN labels(n)[0] AS label, count(n) AS nodes
ORDER BY label;

// Expect: OWNS 8, LIVES_IN 4, PURCHASED 24
MATCH ()-[r]->() RETURN type(r) AS relationship, count(r) AS count
ORDER BY relationship;

// Reconcile purchases against source: must equal source row count (24)
MATCH ()-[p:PURCHASED]->() RETURN count(p) AS purchased_relationships;

// Spot-check the duplicate that started it all (account 123458, JPM)
MATCH (a:Account {account_id:'123458'})-[p:PURCHASED]->(s:Stock {ticker:'JPM'})
RETURN p.purchase_id, p.number_of_shares, p.purchase_date, p.price_per_share;
