## The big idea

Imagine a school where every project needs six different teachers to sign off. Nothing moves. Now imagine each class can finish its own project start-to-finish, and there's a supply closet everyone can grab from without asking. That second school is what **Team Topologies** is aiming for.

It's a way of arranging teams so work *flows* instead of getting stuck waiting on other people. Two rules underneath it:

- **Conway's Law:** whatever your org chart looks like, your product will end up looking like it too. Four disconnected teams → four disconnected products.
- **Cognitive load:** a team can only hold so much in its head. Overload them and everything slows down.

## The four team types

| Type | Job | Pizza shop version |
|---|---|---|
| **Stream-aligned** | Owns one slice of value end-to-end. Most teams should be this. | The crew that takes an order, makes the pizza, boxes it |
| **Platform** | Builds self-service tools so the stream teams don't have to | The kitchen: ovens, prepped dough, walk-in fridge |
| **Complicated-subsystem** | Owns one genuinely hard piece needing rare expertise | The one person who maintains the wood-fired oven |
| **Enabling** | Coaches other teams, then leaves | A visiting chef teaching a new technique for two weeks |

## The three ways teams talk

1. **Collaboration** — two teams work shoulder-to-shoulder. Great for inventing new things, expensive in time. Should be temporary.
2. **X-as-a-Service** — one team just *uses* what another provides, like using an app. Low chatter, fast, boring in a good way.
3. **Facilitating** — one team teaches another for a while, then steps back.

The big move is graduating a relationship from #1 to #2. Collaborate to build the thing, then turn it into a service.

## Real-world examples

**Amazon** — "two-pizza teams," small enough to be fed by two pizzas, each owning a service completely. That's stream-aligned thinking. Their internal rule that every team must expose its work as a service is X-as-a-Service made mandatory.

**Netflix** — the "paved road": a set of internal tools teams are strongly encouraged (not forced) to use. Classic platform team. You can go off-road, but then you support yourself.

**Spotify** — squads owning features end-to-end, with chapters/guilds spreading skills sideways. The squad is stream-aligned; the guild does enabling work.

**A bank's fraud-detection group** — a small team of specialists owning the fraud model. Nobody else needs to understand it; they just call the API. Complicated-subsystem.

## A process you can actually run

1. **Map the value streams.** What are the 4–8 things your org actually delivers to someone who cares? Those become your stream-aligned teams.
2. **Measure cognitive load.** Ask each team: "Is what you own too much to hold in your head?" If yes, split the work or push the hard parts down to a platform.
3. **Find the fracture planes.** Split along natural seams — different customers, different risk levels, different change speeds — not along technology layers.
4. **Assign team types.** Everything that isn't stream-aligned needs to justify itself as platform, complicated-subsystem, or enabling.
5. **Name the interaction mode** for each pair of teams that touch, and write down *when collaboration ends*. Unlimited collaboration is a smell.
6. **Sense and adapt.** Revisit quarterly. Team structure is a living thing, not an org chart you file away.

## Where a cloud infrastructure team fits in a data org

The cloud infra team is a **platform team**. Its customers are internal — the data teams — and its product is a self-service data platform.

- **Stream-aligned:** Marketing Analytics, Finance Reporting, Customer 360 — each owns its data products end-to-end.
- **Platform (cloud infra + data platform):** warehouse provisioning, orchestration (Airflow/Dagster), Terraform modules, CI/CD, monitoring, cost controls, security guardrails, access management.
- **Complicated-subsystem:** the real-time streaming engine, or the ML feature store — genuinely hard, rare skills, stable API.
- **Enabling:** a data governance / engineering-practices team that spends six weeks with a stream team teaching dbt testing and data contracts, then moves on.

**The success test:** a data team should be able to spin up a new pipeline environment in minutes without filing a ticket. If your cloud infra team is a ticket queue, it's a bottleneck wearing a platform costume.

**How they interact:** mostly X-as-a-Service. But when Marketing Analytics needs something genuinely new — say, first-ever streaming ingestion — the two teams *collaborate* for a quarter, build it together, then the platform team productizes it and the relationship drops back to as-a-service.

One more rule worth stealing: build the **Thinnest Viable Platform**. Don't build every feature imaginable. Build the smallest set of things that removes the most pain, and let real demand tell you what's next.