# [Project Title]: Technical Proposal

| Field | Value |
|---|---|
| **Author(s)** | [Name, role] |
| **Reviewers** | [Names] |
| **Status** | Draft / In Review / Approved / Rejected |
| **Version** | 0.1 |
| **Date** | YYYY-MM-DD |
| **Related docs** | [Links to PRD, tickets, prior proposals] |

---

## 1. Summary

> One paragraph. What are you proposing, why, and what is the expected outcome? A reader should be able to stop here and understand the gist.

## 2. Problem Statement

- **Current situation:** What exists today and how it works.
- **Pain points:** What is broken, slow, costly, or missing. Quantify where possible (latency, error rate, cost, developer hours).
- **Impact of not acting:** What happens if this stays unresolved.

## 3. Goals and Non-Goals

### Goals
- [ ] Goal 1 (measurable)
- [ ] Goal 2

### Non-Goals
- Explicitly out of scope item 1
- Explicitly out of scope item 2

## 4. Requirements

### Functional
| ID | Requirement | Priority (Must/Should/Could) |
|---|---|---|
| FR-1 | | |
| FR-2 | | |

### Non-Functional
| ID | Requirement | Target |
|---|---|---|
| NFR-1 | Performance | e.g. p99 < 200 ms |
| NFR-2 | Availability | e.g. 99.9% |
| NFR-3 | Security / Compliance | |
| NFR-4 | Scalability | |

## 5. Proposed Solution

### 5.1 Overview
High-level description of the approach.

### 5.2 Architecture
```
[Insert diagram, or describe components and data flow]
Client → API Gateway → Service A → Database
                     ↘ Service B → Queue → Worker
```

### 5.3 Components
| Component | Responsibility | Owner |
|---|---|---|
| | | |

### 5.4 Data Model / APIs
```
[Schemas, endpoints, message formats]
```

### 5.5 Key Design Decisions
| Decision | Options considered | Chosen | Rationale |
|---|---|---|---|
| | | | |

## 6. Alternatives Considered

### Alternative A: [Name]
- **Description:**
- **Pros:**
- **Cons:**
- **Why rejected:**

### Alternative B: [Name]
- **Description:**
- **Pros:**
- **Cons:**
- **Why rejected:**

## 7. Implementation Plan

| Phase | Deliverable | Estimate | Dependencies |
|---|---|---|---|
| 1 | | | |
| 2 | | | |
| 3 | | | |

**Milestones:**
- [ ] M1 – [date]
- [ ] M2 – [date]

**Rollout strategy:** (feature flags, canary, migration steps, rollback plan)

## 8. Testing and Validation

- **Unit / integration tests:**
- **Load / performance tests:**
- **Security review:**
- **Success metrics:** How will you know it worked? (KPIs, dashboards)

## 9. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| | Low/Med/High | Low/Med/High | |

## 10. Cost and Resources

- **People:** Roles and time commitment
- **Infrastructure:** Estimated monthly/annual cost
- **Third-party services / licenses:**
- **Ongoing maintenance:**

## 11. Security, Privacy, and Compliance

- Data handled and its classification
- Authentication / authorization model
- Regulatory considerations (GDPR, SOC 2, HIPAA, etc.)

## 12. Open Questions

| # | Question | Owner | Status |
|---|---|---|---|
| 1 | | | Open |

## 13. Approval

| Role | Name | Decision | Date |
|---|---|---|---|
| Tech Lead | | Approve / Reject | |
| Engineering Manager | | | |
| Security | | | |

## Appendix

- Glossary
- References and links
- Detailed benchmarks or supporting data

---

## Changelog

| Version | Date | Author | Change |
|---|---|---|---|
| 0.1 | | | Initial draft |
