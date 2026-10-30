# COP5615 - Distributed Operating System Principles
## Project 3: Pastry P2P Protocol & Object Access Service (Actor Model in Erlang)

---

### Team Members
* **Suhrudh Reddy Pyata** (UFID: **32561781**) — *Single team member*

---

## 1. What is Working

1. **Pastry Protocol Implementation (Full Specification)**:
   * **128-bit Circular Identifier Space**: 128-bit node IDs and keys represented in base $2^b = 16$ ($b=4$, 32 hexadecimal digits). Distance calculations handle circular ring modular wrap-around seamlessly.
   * **State Maintenance (per Actor)**:
     * **Leaf Set ($L$, $|L| = 16$)**: Maintained as $L/2 = 8$ counter-clockwise (smaller) and $L/2 = 8$ clockwise (larger) neighbors along the circular ring.
     * **Routing Table ($R$, $32 \times 16$)**: 32 rows and 16 columns corresponding to prefix length $l$ and next hex digit $d$.
     * **Neighborhood Set ($M$, $|M| = 16$)**: Initialized with bootstrap and proximate peer records discovered along the join path, and actively queried during fallback routing.
   * **Pastry Routing Algorithm (Section 2.2)**:
     * **Step 1 (Leaf Set Range)**: Evaluates whether target key $D$ falls within the arc of the leaf set. If so, routes directly to the leaf node (or self) minimizing numerical distance $|D - L_i|$.
     * **Step 2 (Routing Table)**: If $D$ is outside the leaf set range, identifies common prefix length $l = \text{shl}(A, D)$ and forwards to $R[l][D_l]$.
     * **Step 3 (Fallback Routing)**: If $R[l][D_l]$ is null or unreachable, routes to any node $T \in L \cup R \cup M$ where $\text{shl}(T, D) \ge l$ and $|T - D| < |A - D|$.
   * **Node Join Protocol (Section 2.4)**:
     * New node $X$ bootstraps through a known node $A$.
     * Routes join message with key $X$. Intermediate nodes at hop $i$ forward row $i$ of their routing table.
     * Destination node $Z$ (numerically closest to $X$) supplies its leaf set.
     * Node $X$ populates its leaf set and routing table and transmits update messages to all discovered peers.
     * Existing peers dynamically integrate $X$ into their routing structures.

2. **Application Layer: Object Access Service (Section 2.3 API)**:
   * Implements a distributed key-value store associating 128-bit keys with strings.
   * Supports both actor messages and synchronous client APIs:
     * `pastry_node:put(NodePid, KeyHex, ValueStr)`: Routes the object store request across the overlay to the peer with the numerically closest nodeId and returns `{ok, DeliveringPid}`.
     * `pastry_node:get(NodePid, KeyHex)`: Routes the retrieval request to the closest live peer and returns `{ok, ValueStr, DeliveringPid}`.
   * Core callbacks:
     * `route(Msg, Key)`: Routes object access messages to the closest live peer.
     * `deliver(Msg, Key)`: Invoked at destination peer; stores or retrieves object in local `app_store` map and confirms completion to caller and coordinator.
     * `forward(Msg, Key, NextHopId)`: Upcall invoked at each intermediate hop along the path.
     * `newLeafs(LeafSet)`: Upcall invoked when the leaf set updates.

3. **Actor Model Concurrency**:
   * Pure Erlang actor model implementation.
   * Exactly **one actor process per peer modeled** (`pastry_node.erl`).
   * No shared memory, locks, or non-actor concurrency.

4. **Rigorous Routing Accuracy Verification**:
   * The coordinator and test suites verify not only delivery success, but also **routing correctness**: confirming that every delivery lands on the peer actor with the true minimum circular distance to the key among all live nodes in the overlay.
   * On healthy networks, routing accuracy is **100.0%**.

5. **Command-Line Interface & Timing**:
   * Standard invocation: `project3 numNodes numRequests [intervalMs]`
   * Adheres to **1 request/second per peer** by default using timer scheduling.
   * Configurable request interval allows fast execution for grading and benchmarks.
   * Clean console summaries showing total delivered requests, routing accuracy, total runtime, and average hop count.

6. **Bonus: Fault Tolerance & Self-Healing (20% Bonus)**:
   * **Node Failure Model**: Handles dynamic node crashes (process exit).
   * **Connection Failure Model**: Evaluated with **uniformly shuffled random pair link cuts** across the entire overlay.
   * **Transient Connection Failure Model**: Evaluated with temporary glitches followed by automatic link restoration via `restore_link`.
   * **Self-Healing State Repair**:
     * **Leaf Set Repair**: Detects dead leaf members and queries the outermost live leaf node on that side (`request_leaf_set`) to restore leaf set integrity.
     * **Routing Table Repair**: Queries peer nodes in the same row (`request_routing_entry`) to recover dead or missing routing entries.
     * **Periodic Background Maintenance**: Each peer actor runs a periodic maintenance timer that prunes dead actors and triggers repair.
     * **Fault-Tolerant Dynamic Rerouting**: Zero-downtime routing around dead or unreachable nodes via $L \cup R \cup M$ fallback rules.
   * Tested up to 30% node crashes and 400 dropped links with **100% request delivery rate** and **>99.8% routing correctness**.

---

## 2. Largest Network Handled

The system was evaluated across progressively larger topologies up to **10,000 nodes**:

| Network Size ($N$) | Theoretical $\log_{16}(N)$ | Total Requests | Build Time | Request Time | Average Hops |
|:------------------:|:--------------------------:|:--------------:|:----------:|:------------:|:------------:|
| **100**            | 1.66                       | 200            | 103 ms     | 62 ms        | **1.74**     |
| **500**            | 2.24                       | 1,000          | 263 ms     | 46 ms        | **2.26**     |
| **1,000**          | 2.49                       | 2,000          | 595 ms     | 162 ms       | **2.60**     |
| **2,000**          | 2.74                       | 4,000          | 1,344 ms   | 675 ms       | **2.84**     |
| **5,000**          | 3.07                       | 10,000         | 3,821 ms   | 1,204 ms     | **3.11**     |
| **10,000**         | 3.32                       | 20,000         | 8,007 ms   | 3,639 ms     | **3.39**     |

* **Largest Network Handled**: **10,000 nodes** (peer actors).
* **Key Finding**: Average hop counts closely match $\log_{16}(N)$ at all scales, confirming Pastry's $O(\log_{2^b} N)$ logarithmic routing bound.
* **Throughput**: 10,000 nodes were initialized, joined, and routed 20,000 requests in approximately **11.6 seconds total** (including end-to-end routing accuracy verification on all 20,000 deliveries).

---

## 3. How to Run

### Compilation
Compile all Erlang source files using `make` or `erlc`:
```bash
make
# or
erlc pastry_util.erl pastry_node.erl project3.erl project3_bonus.erl benchmark_scale.erl test_pastry.erl test_network.erl
```

### Running Unit & Network Tests
To execute the comprehensive test suite (including ring arithmetic, leaf set tests, routing table tests, cross-node PUT/GET object access assertions, and 50-node network simulation):
```bash
make test
# or
erl -noshell -pa . -s test_pastry run -s init stop
erl -noshell -pa . -eval "test_network:run(50, 5), halt()."
```

### Running Scalability Benchmark
To run the automated scalability benchmark across 100 to 10,000 nodes:
```bash
make scale
# or
erl -noshell -pa . -s benchmark_scale run -s init stop
```

### Running the Main Assignment (`project3`)
The script can be executed on any OS through multiple standard methods:

**Method 1: Direct Command (Windows batch / CMD / PowerShell)**
```cmd
project3 100 5
# or
.\project3 100 5
```

**Method 2: Unix / Mac / Linux (escript / executable)**
```bash
./project3 100 5
# or
escript project3 100 5
```

**Method 3: Native Erlang CLI**
```bash
erl -noshell -pa . -s project3 main 100 5 -s init stop
```

*Parameters*:
* `numNodes`: Number of peer actors to spawn in the overlay.
* `numRequests`: Number of requests each peer issues (at 1 request/second).
* *(Optional 3rd argument)*: `[intervalMs]` (defaults to `1000` ms for 1 request/second). For fast testing/grading, an interval such as `50` or `100` ms can be passed.

**Sample Output**:
```
=============================================================
  Pastry P2P Network Simulation (Project 3)
=============================================================
Team Member: Suhrudh Reddy Pyata (UFID: 32561781)
Peers (Nodes):        100
Requests per peer:    5
Request interval:     1000 ms (1.0 req/sec per peer)
-------------------------------------------------------------
[Network Join Phase] Initializing and joining 100 peer actors...
[Network Ready] All 100 peers joined successfully in 68 ms.
[Request Phase] Starting 500 requests (1.0 requests/sec per peer)...
-------------------------------------------------------------
Simulation Summary:
  Requests Delivered: 500 / 500 (100.0%)
  Routing Accuracy:   500 / 500 (100.0% at closest node)
  Total Simulation Time: 4085 ms (4.09 s)
Average number of hops = 1.74
=============================================================
```

---

## 4. Bonus: Node, Link & Transient Failure Models

### Running the Bonus Benchmark Suite
To execute the automated resilience benchmark covering node failure, uniformly shuffled link failure, and transient link glitch models:
```bash
make bonus
# or
erl -noshell -pa . -s project3_bonus run_benchmark -s init stop
```

### Running Custom Failure Scenarios
```cmd
# Windows:
project3_bonus numNodes numRequests numFailures failureType

# Linux / Mac:
./project3_bonus numNodes numRequests numFailures failureType
# or
escript project3_bonus numNodes numRequests numFailures failureType
```
* `failureType`:
  * `node`: Kills `numFailures` random nodes (`exit(normal)`).
  * `connection` / `link`: Permanently severs links between uniformly shuffled node pairs.
  * `transient`: Temporarily severs links and auto-recovers them via `restore_link`.

**Example**:
```cmd
project3_bonus 200 5 40 node
```

---

## 5. File Structure
* [project3.erl](file:///c:/Users/s/Videos/project3/project3.erl): Main CLI driver and coordinator process with routing accuracy verification.
* [pastry_node.erl](file:///c:/Users/s/Videos/project3/pastry_node.erl): The Pastry peer actor (join, routing, key-value object store, leaf & routing repair, periodic maintenance).
* [pastry_util.erl](file:///c:/Users/s/Videos/project3/pastry_util.erl): 128-bit circular distance arithmetic, hex conversions, leaf set, routing table, and $L \cup R \cup M$ fallback search.
* [project3_bonus.erl](file:///c:/Users/s/Videos/project3/project3_bonus.erl): Bonus failure injector (node, connection, transient), accuracy verifier, and resilience test suite.
* [benchmark_scale.erl](file:///c:/Users/s/Videos/project3/benchmark_scale.erl): Large-scale performance benchmark up to 10,000 nodes.
* [test_pastry.erl](file:///c:/Users/s/Videos/project3/test_pastry.erl): Unit tests and multi-node routing & object access assertions.
* [test_network.erl](file:///c:/Users/s/Videos/project3/test_network.erl): Multi-node network join and delivery verification test.
* [project3](file:///c:/Users/s/Videos/project3/project3) / [project3.bat](file:///c:/Users/s/Videos/project3/project3.bat): Executable launchers for Unix and Windows.
* [project3_bonus](file:///c:/Users/s/Videos/project3/project3_bonus) / [project3_bonus.bat](file:///c:/Users/s/Videos/project3/project3_bonus.bat): Bonus executable launchers.
* [Makefile](file:///c:/Users/s/Videos/project3/Makefile): Compilation, test, scale, and bonus targets.
* [BONUS_REPORT.md](file:///c:/Users/s/Videos/project3/BONUS_REPORT.md): Detailed report and empirical evaluation of fault tolerance and resilience.
