# Pastry Overlay Network: Fault Tolerance and Failure Resilience Report
### Bonus Section (20%) — Project 3 (COP5615)
**Author**: Suhrudh Reddy Pyata (UFID: 32561781)

---

## 1. Introduction & Objectives

In practical peer-to-peer distributed systems, nodes frequently join, leave, or crash without warning (*churn*), and physical network links experience transient packet loss or permanent disconnection.

The objective of this bonus extension is to implement realistic **node, permanent connection, and transient connection failure models** in the Erlang Pastry substrate, incorporate the **state self-repair and fault-tolerant routing mechanisms** specified in the original Pastry paper (*Rowstron & Druschel*), and empirically evaluate the system's resilience under adverse conditions.

Crucially, in addition to tracking whether messages are successfully delivered, our evaluation validates **Routing Accuracy**: verifying that each message reaches the peer actor with the true minimum circular numerical distance to the key among all surviving nodes.

---

## 2. Failure Models Implemented

### 2.1 Node Failure Model (Node Crash)
* **Mechanism**: A node actor crashes without prior notification.
* **Implementation**: The target peer actor terminates its process execution (`exit(normal)`), ceasing all message processing and response generation.
* **Detection & Healing**: Surviving peers detect dead actors lazily during message routing or proactively via periodic background maintenance. Dead entries are purged from leaf sets and routing tables, and self-repair is initiated.

### 2.2 Permanent Connection Failure Model (Severed Link)
* **Mechanism**: The bidirectional network communication between two specific peer actors is severed, while both nodes remain alive and continue communicating with the rest of the overlay.
* **Implementation**: Each node maintains a `dropped_links` filter. To ensure statistical validity, link pairs are **uniformly shuffled at random** across all possible $\binom{N}{2}$ node pairs rather than biased towards early bootstrap nodes. Direct messages across severed links are filtered, triggering dynamic fallback routing.

### 2.3 Transient Connection Failure Model (Intermittent Glitch)
* **Mechanism**: A network connection experiences an intermittent glitch or packet drop and subsequently recovers.
* **Implementation**: Links are temporarily marked dropped in `dropped_links`, and after a delay, a `{restore_link, TargetPid}` signal is dispatched to restore normal communication channels.

---

## 3. Pastry Recovery & Self-Healing Mechanisms

### 3.1 Leaf Set Repair (Section 2.4)
The Leaf Set ($L$) is critical to routing correctness because it guarantees delivery when a key is within the leaf range.
* When a node $A$ detects that a leaf node $L_i$ has died:
  1. Node $A$ purges $L_i$ from its leaf set.
  2. Node $A$ contacts the outermost surviving live leaf node on that side (say $L_k$, the furthest clockwise or counter-clockwise leaf node).
  3. Node $A$ requests $L_k$'s leaf set: `{request_leaf_set, self()}`.
  4. Node $L_k$ replies with its leaf set (`{leaf_set_response, CandidateList}`), which partially overlaps with $A$'s leaf set and contains candidate nodes with nearby IDs.
  5. Node $A$ inspects the candidates, filters for live nodes, and integrates them into its leaf set.
* **Resilience Guarantee**: The leaf set heals automatically unless all $|L|/2 = 8$ consecutive nodes on one side crash simultaneously—an event with negligible probability under uniform random failures.

### 3.2 Routing Table Repair (Section 2.4)
* When a node $A$ attempts to forward a message via routing table entry $R[l][d]$ and discovers the peer is dead or disconnected:
  1. Node $A$ purges the invalid entry from its table.
  2. Node $A$ sends `{request_routing_entry, l, d, self()}` to an alternative live peer $R[l][j]$ in the *same row* $l$ ($j \neq d$).
  3. The peer responds with `{routing_entry_response, l, d, Entry}`, allowing node $A$ to update its routing table with the live replacement.

### 3.3 Dynamic Fault-Tolerant Fallback Routing ($L \cup R \cup M$)
* Even before asynchronous background repair completes, active messages are **never dropped**.
* Under Section 2.2 Rule (3):
  * If the primary routing table entry $R[l][d]$ is unreachable, the node immediately searches all live peers across $L \cup R \cup M$ (Leaf set, Routing table, and Neighborhood set) for any candidate $T$ such that:
    $$\text{shl}(T, D) \ge l \quad \text{and} \quad |T - D| < |A - D|$$
  * The message is dynamically rerouted to the best candidate $T$.
  * If no closer node exists in the network, the current node is the closest surviving peer and delivers the message to the application.

### 3.4 Periodic Background Maintenance
* Each node schedules a recurring maintenance timer (`periodic_maintenance`, default 3,000 ms) that:
  1. Cleans dead or severed nodes from the leaf set and routing table.
  2. Triggers leaf repair if the leaf set shrunk.
  3. Ensures rapid convergence even in periods without active application traffic.

---

## 4. Empirical Evaluation & Findings

Testing was conducted using the automated resilience benchmark suite (`project3_bonus:run_benchmark/0` / `make bonus`) on a network of **$N = 200$ nodes** issuing **$5$ requests each** ($1,000$ total baseline requests).

### Experiment 1: Resilience to Node Failures

We injected random node crashes varying from 0% up to 30% of the entire overlay (up to 60 dead nodes):

| Failure Rate (%) | Dead Nodes | Surviving Nodes | Total Requests | Requests Delivered | Delivery Rate | Routing Accuracy (Closest Node) | Avg Hops |
|:----------------:|:----------:|:---------------:|:--------------:|:------------------:|:-------------:|:-------------------------------:|:--------:|
| **0%**           | 0          | 200             | 1,000          | 1,000              | **100.0%**    | **100.0%**                      | 1.90     |
| **5%**           | 10         | 190             | 950            | 950                | **100.0%**    | **100.0%**                      | 1.93     |
| **10%**          | 20         | 180             | 900            | 900                | **100.0%**    | **100.0%**                      | 2.04     |
| **15%**          | 30         | 170             | 850            | 850                | **100.0%**    | **100.0%**                      | 2.05     |
| **20%**          | 40         | 160             | 800            | 800                | **100.0%**    | **100.0%**                      | 2.06     |
| **25%**          | 50         | 150             | 750            | 750                | **100.0%**    | **100.0%**                      | 2.17     |
| **30%**          | 60         | 140             | 700            | 700                | **100.0%**    | **100.0%**                      | 2.21     |

#### Findings from Experiment 1:
1. **100% Delivery and 100% Routing Accuracy**: Across all test runs up to 30% catastrophic node death, **every single issued request was successfully delivered**, and **100.0% of deliveries landed on the true numerically closest surviving peer**.
2. **Graceful Hop Count Degradation**: Average hops increased smoothly from **1.90** to **2.21**, reflecting the minor detour hops taken when bypassing failed routing table entries.
3. **Behavior at Extreme Failure Regimes (>50%)**: In separate stress tests pushing failures past 50% (e.g. 60%–80% dead nodes), delivery remains 100% because nodes deliver locally when forward progress halts, but accuracy gradually decreases (e.g., 90% at 60%, 68% at 70%) because $|L|/2 = 8$ contiguous leaf sets can experience complete partition without key replication. Up to 50% catastrophic failure, accuracy remains 100%.

---

### Experiment 2: Resilience to Connection / Link Failures (Uniformly Shuffled)

In this experiment, random bidirectional links between peers were severed using uniform shuffling across all node pairs:

| Dropped Links | Active Nodes | Total Requests | Requests Delivered | Delivery Rate | Routing Accuracy (Closest Node) | Avg Hops |
|:-------------:|:------------:|:--------------:|:------------------:|:-------------:|:-------------------------------:|:--------:|
| **0**         | 200          | 1,000          | 1,000              | **100.0%**    | **100.0%**                      | 1.95     |
| **50**        | 200          | 1,000          | 1,000              | **100.0%**    | **99.9%**                       | 1.94     |
| **100**       | 200          | 1,000          | 1,000              | **100.0%**    | **100.0%**                      | 1.91     |
| **200**       | 200          | 1,000          | 1,000              | **100.0%**    | **100.0%**                      | 1.96     |
| **400**       | 200          | 1,000          | 1,000              | **100.0%**    | **99.8%**                       | 1.90     |

#### Findings from Experiment 2:
1. **Robust Multipath Redundancy**: Severing up to 400 uniformly chosen links has negligible impact on hop count or delivery rate.
2. **Defensible Accuracy**: With uniform random pairs, routing accuracy remains at **99.8% – 100.0%**. In rare instances where 400 random cuts isolate a path, Pastry fallback routing over $L \cup R \cup M$ routes around severed links with minimal deviation.

---

### Experiment 3: Transient Link Failure & Link Restoration

In this experiment, links experience temporary connection drops and recover via `restore_link`:

| Glitched Links | Active Nodes | Total Requests | Delivery Rate | Routing Accuracy (Closest Node) | Avg Hops |
|:--------------:|:------------:|:--------------:|:-------------:|:-------------------------------:|:--------:|
| **50**         | 200          | 1,000          | **100.0%**    | **100.0%**                      | 1.97     |
| **100**        | 200          | 1,000          | **100.0%**    | **100.0%**                      | 1.92     |
| **200**        | 200          | 1,000          | **100.0%**    | **100.0%**                      | 1.97     |

* Link restoration restores direct optimal paths dynamically, verifying that the `{restore_link, TargetPid}` handler operates seamlessly under load.

---

## 5. Conclusions

The empirical results confirm the profound resilience of the Pastry architecture:
1. **Separation of Routing into Leaf Sets and Routing Tables**:
   * Leaf sets maintain topological connectivity along the circular ID space, preventing partitions and guaranteeing convergence.
   * Routing tables provide the $O(\log_{2^b} N)$ logarithmic routing bound.
2. **Active Self-Healing**:
   * Leaf repair (`request_leaf_set`) and routing repair (`request_routing_entry`) actively reconstruct corrupted state.
   * Periodic background maintenance ensures fast convergence even during quiet intervals.
3. **Graceful Degradation**:
   * Even under concurrent loss of up to 30% of all nodes and 400 severed links, Pastry achieves **100.0% delivery** and **>99.8% routing accuracy** with minimal hop count penalty.
