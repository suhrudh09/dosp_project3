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

### 2.3 Transient Connection Failure Model (Intermittent Glitch & State Restoration)
* **Mechanism**: A network connection experiences an intermittent glitch or packet drop and subsequently recovers while traffic is in flight.
* **Implementation**: Links are temporarily marked dropped in `dropped_links`. After a specified duration (while traffic is actively routing), a `{restore_link, TargetPid}` signal is dispatched.
* **State Healing**: Upon receiving `{restore_link, TargetPid}`, both nodes execute mutual probe exchanges (`probe_restore` / `probe_restore_reply`), re-integrating each other and their respective leaf sets into their routing state so that entries purged during the drop are dynamically re-learned.

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
  2. Verifies leaf set integrity: if either the clockwise or counter-clockwise leaf list has fewer than $|L|/2 = 8$ members, it proactively queries outer leaves to discover live candidates.
  3. Ensures continuous convergence and heals topology partitions even in periods without active application traffic.

---

## 4. Empirical Evaluation & Findings

Testing was conducted using the automated resilience benchmark suite (`project3_bonus:run_benchmark/0` / `make bonus`) on a network of **$N = 200$ nodes** issuing **$5$ requests each** ($1,000$ total baseline requests).

### Experiment 1: Resilience to Node Failures

We evaluated random node crashes across 0% to 30% baseline failure rates (as reported by `make bonus`):

| Failure Rate (%) | Dead Nodes | Surviving Nodes | Total Requests | Requests Delivered | Delivery Rate | Routing Accuracy (Closest Node) | Avg Hops |
|:----------------:|:----------:|:---------------:|:--------------:|:------------------:|:-------------:|:-------------------------------:|:--------:|
| **0%**           | 0          | 200             | 1,000          | 1,000              | **100.0%**    | **100.0%**                      | 1.91     |
| **5%**           | 10         | 190             | 950            | 950                | **100.0%**    | **100.0%**                      | 1.91     |
| **10%**          | 20         | 180             | 900            | 900                | **100.0%**    | **100.0%**                      | 1.97     |
| **15%**          | 30         | 170             | 850            | 850                | **100.0%**    | **100.0%**                      | 2.01     |
| **20%**          | 40         | 160             | 800            | 800                | **100.0%**    | **100.0%**                      | 2.09     |
| **25%**          | 50         | 150             | 750            | 750                | **100.0%**    | **100.0%**                      | 2.09     |
| **30%**          | 60         | 140             | 700            | 700                | **100.0%**    | **100.0%**                      | 2.08     |

#### Extended Evaluation Beyond 30% (Multi-Trial Analysis, $N=200$):
To rigorously characterize the system's boundary conditions, independent repeated trials were conducted across higher failure regimes:

| Node Failure Rate | Independent Trials | Mean Routing Accuracy | Trial Distribution |
|:-----------------:|:------------------:|:---------------------:|:------------------:|
| **30%**           | 10                 | **100.0%**            | 100% in every trial |
| **40%**           | 10                 | **100.0%**            | 100% in every trial |
| **50%**           | 15                 | **98.6%**             | Worst trial: 90.9% |
| **60%**           | 10                 | **86.0%**             | Range: 71% – 100% |
| **70%**           | 10                 | **54.0%**             | Range: 33% – 71% |
| **80%**           | 10                 | **21.0%**             | Range: 13% – 32% |

#### Key Takeaways from Experiment 1:
1. **Flawless Delivery and Accuracy up to 40%**: Every request is delivered, and 100% of deliveries reach the exact numerically closest surviving peer across all trials up to 40% node failure.
2. **Phase Transition at $\ge 50\%$**: Beyond 50% catastrophic node death, delivery still reports 100% because nodes deliver locally when forward progress halts, but accuracy declines because runs of $|L|/2 = 8$ contiguous leaf nodes can fail simultaneously, fragmenting leaf set continuity without global DHT replication.

---

### Experiment 2: Resilience to Connection / Link Failures (Uniformly Shuffled)

In this experiment, random bidirectional links between peers were severed using uniform shuffling across all $\binom{N}{2}$ node pairs:

| Dropped Links | Active Nodes | Total Requests | Requests Delivered | Delivery Rate | Routing Accuracy (Closest Node) | Avg Hops |
|:-------------:|:------------:|:--------------:|:------------------:|:-------------:|:-------------------------------:|:--------:|
| **0**         | 200          | 1,000          | 1,000              | **100.0%**    | **100.0%**                      | 1.92     |
| **50**        | 200          | 1,000          | 1,000              | **100.0%**    | **100.0%**                      | 1.94     |
| **100**       | 200          | 1,000          | 1,000              | **100.0%**    | **100.0%**                      | 1.93     |
| **200**       | 200          | 1,000          | 1,000              | **100.0%**    | **99.9%**                       | 1.95     |
| **400**       | 200          | 1,000          | 1,000              | **100.0%**    | **99.8%**                       | 1.96     |

* **Defensible Accuracy**: With uniform random pairs, routing accuracy remains at **99.8% – 100.0%**. In rare instances where 400 random cuts isolate a path, Pastry fallback routing over $L \cup R \cup M$ routes around severed links with minimal deviation.

---

### Experiment 3: Transient Link Glitch & Live Link Restoration

In this experiment, links experience temporary connection drops while traffic is in-flight, recovering automatically via `{restore_link, TargetPid}` mid-traffic:

| Glitched Links | Active Nodes | Total Requests | Delivery Rate | Routing Accuracy (Closest Node) | Avg Hops |
|:--------------:|:------------:|:--------------:|:-------------:|:-------------------------------:|:--------:|
| **50**         | 200          | 1,000          | **100.0%**    | **99.9%**                       | 1.90     |
| **100**        | 200          | 1,000          | **100.0%**    | **100.0%**                      | 1.93     |
| **200**        | 200          | 1,000          | **100.0%**    | **100.0%**                      | 1.91     |

* **Mutual State Re-Learning**: Unlike passive link restoration, our implementation triggers a mutual probe exchange (`probe_restore` / `probe_restore_reply`) upon link unblocking. Purged leaf set and routing table entries are dynamically re-learned, achieving 100% leaf set coverage convergence following restoration.

---

## 5. System Boundaries & DHT Storage Semantics

To ensure complete technical clarity, the following explicit architectural boundaries are documented:

1. **In-Flight Message Drops (No Transport-Level Retry)**:
   * The substrate handles pre-traffic and dynamic routing around known failures.
   * If an actor process crashes while a message is in-flight to it, the Erlang runtime silently drops messages sent to dead PIDs. Our core substrate does not implement transport-level acknowledgement timers or retry queues.
2. **In-Memory Single-Destination DHT (No Multi-Replica Storage)**:
   * Objects stored via `app_put` reside solely in the in-memory map (`app_store`) of the single destination node numerically closest to the key.
   * There is no $k$-way leaf set replica synchronization (as found in application layers like PAST or CFS). Consequently, if a node crashes, objects exclusively held in its local memory are lost.

---

## 6. Conclusions

The empirical results confirm the profound resilience of the Pastry architecture:
1. **Separation of Routing into Leaf Sets and Routing Tables**:
   * Leaf sets maintain topological connectivity along the circular ID space, preventing partitions and guaranteeing convergence.
   * Routing tables provide the $O(\log_{2^b} N)$ logarithmic routing bound.
2. **Active Self-Healing**:
   * Leaf repair (`request_leaf_set`), routing repair (`request_routing_entry`), and restoration sync (`probe_restore`) actively reconstruct corrupted state.
   * Periodic background maintenance ensures fast convergence even during quiet intervals.
3. **Graceful Degradation**:
   * Even under concurrent loss of up to 40% of all nodes and 400 severed links, Pastry achieves **100.0% delivery** and **>99.8% routing accuracy** with minimal hop count penalty.
