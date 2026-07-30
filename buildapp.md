# How to Build a Cloud Business App with a Team of 6
### A beginner's guide, written in plain language, with a real example

---

## Part 1: Presentation Slides — The Key Points

Use these bullets as your slide deck. Each heading = one slide.

### Slide 1: What We Are Building
- A **cloud business app**: software that lives on the internet, not on one computer.
- Users **register** (make an account), **log in**, and see only their own stuff.
- Works in a web browser on a laptop or phone. No app store needed to start.
- Example: **TaskTrack** — a job-tracking app for a small landscaping company.

### Slide 2: Why Cloud
- No servers to buy or babysit. We rent computing by the month.
- Grows with us. 10 users or 10,000 users, same code.
- Cheap to start: most tools have a **free tier** (free until you get real customers).
- Automatic backups and security updates from the provider.
- Trade-off: we depend on vendors, and costs rise as we grow.

### Slide 3: The Six Roles on Our Team
- **Product Owner** — decides *what* gets built and in what order.
- **Team Lead / Facilitator** — runs meetings, removes blockers, protects focus.
- **Developer 1 & Developer 2** — build the features (front and back).
- **Designer / Frontend Dev** — makes screens people understand and enjoy.
- **QA + DevOps Engineer** — tests everything, owns deployment and monitoring.

### Slide 4: Our Tech Stack (2026 Defaults)
- **Next.js + TypeScript** — the app itself (screens and logic).
- **PostgreSQL** (via Supabase or Neon) — the database, where data is stored.
- **Managed authentication** (Supabase Auth, Clerk, or Better Auth) — handles sign-up and login.
- **Vercel** — hosting, so the app is live on the internet.
- **Stripe** — payments. **Resend** — emails. **Sentry** — error alerts. **PostHog** — usage analytics.
- **GitHub + GitHub Actions** — code storage and automatic testing/deploying.

### Slide 5: How We Work
- **Kanban or 2-week Scrum sprints** — small batches of work, finished and shipped.
- **Everything in one visible board** — nothing lives only in someone's head.
- **Code review before merge** — two sets of eyes on every change.
- **Automated tests + automatic deploy** — a robot checks and ships our work.
- **Definition of Done** — written rules for when work truly counts as finished.

### Slide 6: The Roadmap
- **Weeks 1–2:** Discovery. Talk to users. Write down the problem.
- **Weeks 3–4:** Design and set up tools, accounts, and the code pipeline.
- **Weeks 5–12:** Build in sprints. Ship something usable every 2 weeks.
- **Weeks 13–14:** Beta test with 5–10 real users. Fix what breaks.
- **Week 15:** Launch (soft launch first, to a small group).
- **Ongoing:** Monitor, patch, improve, repeat.

### Slide 7: How We Know It's Working
- **Product numbers:** sign-ups, weekly active users, users who stay after 30 days.
- **Delivery numbers (DORA):** how often we ship, how long a change takes, how often changes break things, how fast we recover, how much work gets redone.
- **Quality:** bugs found by users vs. found by us. Page load speed. Uptime.
- **Team health:** is anyone burning out? A tired team ships bad software.

### Slide 8: Risks and Honest Trade-offs
- **Scope creep** — the #1 killer. Say "not yet" a lot.
- **Security** — one leaked password list can end the company. Never build auth yourself.
- **Vendor lock-in** — easy tools can be hard to leave later.
- **AI coding tools** — real speed gains, but 2025–2026 research shows they also raise instability. More code shipped means more review and testing, not less.
- **Cost creep** — free tiers end. Model your bill at 10x today's users.

### Slide 9: Budget Snapshot
- Months 1–3 (building, no customers): roughly **$0–$100/month** in tools.
- After launch with a few hundred users: roughly **$150–$500/month**.
- The real cost is people-time, not software.

---

## Part 2: The One Example, Step by Step

Before all the theory, here is one complete walk-through. We will build **TaskTrack**.

**The story:** Green Yard Landscaping has 12 workers. The owner texts everyone their jobs each morning. Workers forget. Nobody knows what got finished. The owner wants one place where she posts jobs and workers check them off.

**What the app must do (version 1 only):**
1. A worker can register and log in.
2. The owner can create a job (title, address, date, who it's for).
3. A worker sees only their own jobs.
4. A worker marks a job "Done" and adds a note.
5. The owner sees a list of everything finished this week.

That's it. Five things. Everything else waits.

### Step 1 — Write the idea in one sentence (Day 1)

> "TaskTrack helps small crew managers assign daily jobs and see what got finished, so they stop losing work in text messages."

If you can't write that sentence, you're not ready to build. This is called a **problem statement**.

### Step 2 — Talk to five real users (Days 1–3)

Interview the owner and four workers. Ask what they do today, not what they want. People are bad at describing features but great at describing pain.

Write down exact quotes. One real quote — "I drove to the wrong house twice last week" — is worth more than a hundred guesses.

### Step 3 — Draw the screens on paper (Days 4–5)

Sketch four screens with a pencil:
- Sign up / Log in
- My Jobs (worker view)
- Create Job (owner view)
- Weekly Report (owner view)

Then rebuild those sketches in **Figma** (free design tool) so everyone sees the same thing. Paper first, software second — paper is faster to throw away.

### Step 4 — Plan the data (Day 6)

Your database is a set of tables, like spreadsheet tabs. TaskTrack needs three:

| Table | What it holds | Example row |
|---|---|---|
| `users` | Each person's account | id: 1, email: maria@..., role: owner |
| `jobs` | Each job to do | id: 55, title: "Mow lawn", address: "12 Oak St", assigned_to: 4, status: "open" |
| `job_notes` | Notes added when finishing | id: 9, job_id: 55, note: "Gate was locked", created_at: ... |

Notice `assigned_to: 4` in the jobs table. That number points at user #4. That link is called a **foreign key** — it's how tables hold hands.

### Step 5 — Set up your accounts and tools (Day 7)

Create free accounts for: **GitHub** (code), **Supabase** (database + auth), **Vercel** (hosting), **Linear or GitHub Projects** (task board), **Sentry** (error alerts), and **Slack or Discord** (team chat).

Have one person create these under a **shared team account**, not their personal email. Otherwise the day they go on vacation, nobody can log in.

### Step 6 — Create the project skeleton (Day 8)

One developer runs these commands once:

```bash
# Create the app
npx create-next-app@latest tasktrack --typescript --tailwind --app
cd tasktrack

# Add the tools we need
npm install @supabase/supabase-js @supabase/ssr

# Put the code on GitHub
git init
git add .
git commit -m "First commit: empty TaskTrack app"
git branch -M main
git remote add origin https://github.com/your-team/tasktrack.git
git push -u origin main
```

Then everyone else runs:

```bash
git clone https://github.com/your-team/tasktrack.git
cd tasktrack
npm install
npm run dev      # opens http://localhost:3000
```

Now all six people have the same app running on their own laptop. That local copy is your **development environment** — your practice field, where mistakes are free.

### Step 7 — Store your secrets safely (Day 8)

Your app needs passwords and keys to reach the database. Put them in a file named `.env.local`:

```
NEXT_PUBLIC_SUPABASE_URL=https://abcdefg.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJhbGci...
SUPABASE_SERVICE_ROLE_KEY=eyJhbGci...
```

Then make sure `.gitignore` contains the line `.env.local`. **This matters enormously.** Secrets pushed to GitHub get found by bots within minutes. Real companies have lost real money this way. Share secrets with teammates through a password manager like 1Password or Bitwarden — never in chat.

### Step 8 — Build the database tables (Day 9)

In the Supabase dashboard, open the SQL editor and run:

```sql
-- Jobs table
create table jobs (
  id bigint primary key generated always as identity,
  title text not null,
  address text,
  scheduled_for date,
  assigned_to uuid references auth.users(id),
  status text not null default 'open',
  created_at timestamptz default now()
);

-- Turn on the security guard
alter table jobs enable row level security;

-- Rule: you may only read jobs assigned to you
create policy "workers see own jobs"
  on jobs for select
  using (auth.uid() = assigned_to);

-- Rule: you may only mark your own jobs done
create policy "workers update own jobs"
  on jobs for update
  using (auth.uid() = assigned_to);
```

Those last two blocks are **Row Level Security (RLS)**. The database itself refuses to hand over another worker's jobs, even if your app code has a bug. Think of it as a locked filing cabinet instead of a note on the door asking people not to peek. For any app with multiple users, turn this on from day one.

### Step 9 — Add sign-up and login (Day 10)

Do **not** write your own password system. Managed auth handles password hashing, reset emails, brute-force protection, two-factor codes, and a dozen attacks you haven't heard of. Building it yourself costs three to four weeks and adds zero customer value.

```typescript
// app/signup/page.tsx  — simplified for clarity
'use client'
import { createBrowserClient } from '@supabase/ssr'
import { useState } from 'react'

export default function SignUp() {
  const supabase = createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
  )
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [message, setMessage] = useState('')

  async function handleSignUp() {
    const { error } = await supabase.auth.signUp({ email, password })
    setMessage(error ? error.message : 'Check your email to confirm!')
  }

  return (
    <div className="max-w-sm mx-auto p-6 space-y-3">
      <h1 className="text-xl font-bold">Create your account</h1>
      <input className="border p-2 w-full" placeholder="Email"
        value={email} onChange={e => setEmail(e.target.value)} />
      <input className="border p-2 w-full" type="password" placeholder="Password"
        value={password} onChange={e => setPassword(e.target.value)} />
      <button className="bg-black text-white px-4 py-2 rounded"
        onClick={handleSignUp}>Sign up</button>
      <p className="text-sm">{message}</p>
    </div>
  )
}
```

Roughly 25 lines, and you have real registration with email confirmation.

### Step 10 — Show each worker their jobs (Days 11–12)

```typescript
// app/jobs/page.tsx — simplified
import { createServerClient } from '@supabase/ssr'
import { cookies } from 'next/headers'

export default async function MyJobs() {
  const supabase = createServerClient(/* ...config with cookies()... */)

  // RLS means this only returns THIS user's jobs. No filter needed.
  const { data: jobs } = await supabase
    .from('jobs')
    .select('*')
    .eq('status', 'open')
    .order('scheduled_for')

  return (
    <main className="p-6">
      <h1 className="text-2xl font-bold mb-4">My Jobs</h1>
      {jobs?.length === 0 && <p>Nothing assigned. Enjoy the quiet.</p>}
      <ul className="space-y-2">
        {jobs?.map(job => (
          <li key={job.id} className="border rounded p-3">
            <strong>{job.title}</strong>
            <div className="text-sm text-gray-600">{job.address}</div>
          </li>
        ))}
      </ul>
    </main>
  )
}
```

### Step 11 — Write one test (Day 13)

A test is code that checks your code. Start small; one test is infinitely better than zero.

```typescript
// tests/jobs.test.ts
import { describe, it, expect } from 'vitest'
import { canMarkDone } from '../lib/jobs'

describe('canMarkDone', () => {
  it('lets the assigned worker finish their job', () => {
    expect(canMarkDone({ assigned_to: 'user-4' }, 'user-4')).toBe(true)
  })
  it('blocks a different worker', () => {
    expect(canMarkDone({ assigned_to: 'user-4' }, 'user-9')).toBe(false)
  })
})
```

### Step 12 — Set up the robot helper (Day 14)

This file tells GitHub to check every code change automatically. This is **CI**, continuous integration.

```yaml
# .github/workflows/ci.yml
name: CI
on: [push, pull_request]

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: 'npm'
      - run: npm ci
      - run: npm run lint      # style check
      - run: npx tsc --noEmit  # type check
      - run: npm test          # run the tests
      - run: npm run build     # make sure it builds
```

Now nobody can merge broken code by accident. The robot never gets tired or distracted, and it doesn't hurt anyone's feelings.

### Step 13 — Put it on the internet (Day 15)

Connect the GitHub repo to Vercel, paste your environment variables into Vercel's settings, and click deploy. From then on:

- Push to `main` → the live site updates automatically.
- Open a pull request → Vercel builds a private **preview link** so teammates can click around the change before it goes live.

That automatic path from "code pushed" to "users have it" is **CD**, continuous delivery. Together: **CI/CD**.

### Step 14 — Watch it and fix it (Day 16 onward)

Add Sentry so you learn about crashes before users email you, and PostHog so you can see which screens people actually use. Then set a rhythm: check errors every morning, review usage numbers every Monday, ship improvements every two weeks.

**You now have a real cloud app with registered users.** Everything below explains the *why* behind those steps, plus the practices that keep a six-person team from tripping over each other.

---

## Part 3: Background — What These Pieces Actually Are

### The parts of any cloud app

Picture a restaurant:

| Restaurant | App | What it does |
|---|---|---|
| Dining room | **Frontend** | What users see and touch: buttons, forms, lists |
| Kitchen | **Backend** | The logic: rules, calculations, permissions |
| Pantry | **Database** | Where information is stored between visits |
| Waiter | **API** | Carries requests from dining room to kitchen and back |
| The building | **Hosting / cloud** | The computers everything runs on |
| Front-door host | **Authentication** | Checks who you are and whether you're allowed in |

### Cloud service models

| Model | Means | Example | Good for |
|---|---|---|---|
| **IaaS** | You rent bare computers | AWS EC2 | Full control, most work |
| **PaaS** | You hand over code, they run it | Vercel, Render, Railway | Small teams — start here |
| **BaaS** | Database + auth + storage as a service | Supabase, Firebase | Skipping backend setup entirely |
| **Serverless** | Code runs only when called | Vercel Functions, Lambda | Spiky, unpredictable traffic |

A six-person team should live in **PaaS + BaaS** territory. You don't have a spare person to be a full-time system administrator, and pretending otherwise is how teams lose a month.

### The three environments

| Environment | Who uses it | Purpose |
|---|---|---|
| **Development** (`localhost`) | One developer, own laptop | Experiment freely, break things |
| **Staging / Preview** | The team + testers | Rehearsal space that mirrors production |
| **Production** | Real customers | The real thing. Treat it with respect. |

Never test with real customer data in development. Use fake data. This isn't just tidiness — in many places it's the law.

### Choosing your stack: options with pros and cons

**Frontend framework**

| Option | Pros | Cons |
|---|---|---|
| **Next.js + React** (default) | Biggest ecosystem, easiest hiring, handles marketing pages and app screens together, best Vercel support | Ships breaking changes often — pin your version and read upgrade guides |
| SvelteKit | Simpler to learn, smaller bundles, pleasant to write | Smaller community, fewer libraries and tutorials |
| Plain React + Vite | Lightweight, fewer opinions | You wire up routing, SEO, and server rendering yourself |
| Django or Rails | Batteries included, superb admin panels | Less slick for highly interactive UI |

**Database**

| Option | Pros | Cons |
|---|---|---|
| **PostgreSQL** (default) | Handles related data properly, huge talent pool, transactions you can trust, row-level security | Requires thinking about structure up front |
| MongoDB | Flexible early, no schema fights | Business data is nearly always relational; teams often migrate to Postgres later at real cost |
| SQLite | Dead simple, zero setup | Harder for multi-server cloud setups |

**Authentication** — the honest rule: never build it yourself.

| Option | Pros | Cons |
|---|---|---|
| **Supabase Auth** | Free with your database, RLS integrates beautifully | You're choosing Supabase for everything |
| **Clerk** | Gorgeous pre-built login screens, fastest to ship, generous free tier | Gets pricey as users grow |
| **Better Auth** | Open source, you own the data, no per-user fee | You run and maintain it |
| Auth0 / AWS Cognito | Enterprise features, SSO, compliance paperwork | Complex setup, expensive |
| Roll your own | "Full control" | 3–4 weeks of work, zero customer value, unlimited ways to leak passwords |

**Hosting**

| Option | Pros | Cons |
|---|---|---|
| **Vercel** | One-click Next.js deploys, preview links, near-zero config | Bills can spike with traffic |
| Netlify / Cloudflare Pages | Cheap, fast global edge | Slightly less Next.js-native |
| Render / Fly.io / Railway | Good for long-running backends and workers | More knobs to understand |
| AWS / GCP / Azure directly | Infinite power, best long-run economics | You need someone who genuinely knows it |

---

## Part 4: Project Management Methods

### Method 1 — Scrum

Work in fixed **sprints** (usually 2 weeks). At the start you pick what fits; at the end you show what's done.

The four meetings:
- **Sprint Planning** (1–2 hours, start of sprint): choose the work.
- **Daily Standup** (10–15 min): each person says yesterday / today / blockers. Standing up keeps it short.
- **Sprint Review** (1 hour, end): demo working software to stakeholders.
- **Retrospective** (45 min, end): what went well, what didn't, one thing we'll change.

**Pros:** clear rhythm, easy to explain to non-technical bosses, forces regular delivery, plenty of hiring pool who know it.
**Cons:** meeting-heavy for six people, mid-sprint emergencies feel disruptive, teams often perform the ceremonies without the substance ("zombie Scrum").

### Method 2 — Kanban

One board, columns left to right: **Backlog → Ready → In Progress → In Review → Testing → Done**. Cards move rightward. The key rule is a **WIP limit**: no more than, say, 2 cards in "In Progress" at once.

**Pros:** simple, flexible, no sprint pressure, exposes bottlenecks instantly (cards piling up in one column = your problem is right there).
**Cons:** without deadlines things can drift; needs discipline; harder to answer "what will be done by March?"

Kanban is often the best fit for a team of six, especially in the messy early months.

### Method 3 — Scrumban

Kanban's flowing board plus Scrum's retrospective and light planning. Skip the rigid sprint commitment.

**Pros:** the useful half of both. **Cons:** less structure means the team must genuinely self-manage.

### Method 4 — Shape Up

Six-week **cycles** with two-week cooldowns. Work is "shaped" into rough solutions with fixed time and flexible scope, and each project gets full autonomy.

**Pros:** long uninterrupted focus, no estimating theater, built for small teams.
**Cons:** six weeks without a deliverable is scary for stakeholders; needs a strong shaper.

### Method 5 — Waterfall

Plan everything, then design, then build, then test, then release. Each phase finishes before the next begins.

**Pros:** predictable paperwork, sometimes required for government or medical contracts.
**Cons:** you find out you built the wrong thing after all the money is spent. Avoid it for a new product where you're still learning what users need.

### Comparison

| Method | Best for | Meeting load | Deadline clarity |
|---|---|---|---|
| Scrum | Teams wanting rhythm and reporting | High | Good |
| Kanban | Steady flow, changing priorities | Low | Weak |
| Scrumban | Most small teams | Medium | Medium |
| Shape Up | Focused product teams | Very low | Medium |
| Waterfall | Fixed-contract work | Medium | Strong (on paper) |

### Tools

| Tool | Best for | Notes |
|---|---|---|
| **Linear** | Small product teams | Fast, opinionated, lovely to use; paid |
| **GitHub Projects** | Teams already on GitHub | Free, sits next to your code |
| **Jira** | Bigger companies, compliance | Powerful, heavy, easy to over-configure |
| **Trello** | Absolute beginners | Simple boards; outgrown quickly |
| **Notion / Confluence** | Documents and decisions | Pair with a proper task tool |

### How to write work items

A **user story** follows: *As a [role], I want [action], so that [benefit].*

> As a **worker**, I want to **mark a job done with a note**, so that **my manager knows what happened without calling me**.

Then add **acceptance criteria** — the checklist that makes "done" objective:

- [ ] "Mark Done" button appears only on my own open jobs
- [ ] A note box appears, optional, max 500 characters
- [ ] Status changes to "done" and the job leaves my open list
- [ ] The manager's weekly report shows the job within 5 seconds
- [ ] Works on a phone screen at 375px wide

Fuzzy stories are where projects go to die. Criteria settle arguments before they start.

---

## Part 5: Standard Practices Every Team Should Follow

### Version control
- **One repository**, one `main` branch that always works.
- **Short-lived branches**: `feature/mark-job-done`, merged within 1–2 days. Long branches turn into painful merges.
- **Pull requests** for every change. At least one reviewer approves. Nobody merges their own work.
- **Clear commit messages**: "Fix crash when job has no address," not "fixes."
- **Protect `main`**: require passing CI and one approval before merge.

### Code review — what to actually look for
1. Does it do what the story said?
2. Is it understandable? Would a new teammate follow it in six months?
3. Are there tests for the tricky parts?
4. Any security holes — unchecked permissions, secrets in code, unvalidated input?
5. Any obviously slow database queries?

Review the code, not the person. "This query runs once per row — could we fetch them together?" beats "why did you write it like that?"

### Testing — the pyramid

| Layer | What it checks | How many |
|---|---|---|
| **Unit tests** | One small function | Many (fast, cheap) |
| **Integration tests** | Pieces working together, e.g. saving to the database | Some |
| **End-to-end tests** | A whole user journey in a real browser (Playwright) | A few (slow, valuable) |
| **Manual/exploratory** | A human poking at it curiously | Always, before release |

Minimum viable discipline: end-to-end tests for **sign up, log in, and your one core action**. Those three breaking is an emergency; anything else is a bug.

### CI/CD
- Every push runs lint, type check, tests, and build.
- Every pull request gets a preview URL.
- Merging to `main` deploys to production automatically.
- **Feature flags** let you ship unfinished code turned off, so half-built work never blocks a release.
- Keep a **rollback** path — one command or click to return to the last good version. In the AI era, being able to restore a known-good state fast matters more than ever.

### Security basics (OWASP-flavored, plain English)
- **Never build your own auth.** Said three times on purpose.
- **Require MFA** for your team's admin accounts, minimum.
- **Least privilege**: give each person and service only the access they need.
- **Row Level Security** in the database so user A can never see user B's data.
- **Validate every input** on the server. Browser checks are a convenience, not a defense.
- **Never trust data from the browser** about who someone is or what they may do.
- **Secrets in a secret manager**, never in code, never in chat.
- **Keep dependencies updated** — turn on Dependabot; it opens the upgrade pull requests for you.
- **HTTPS everywhere**, non-negotiable.
- **Rate limit** login attempts so nobody can guess passwords endlessly.

### Privacy and legal
- Collect only data you actually need.
- Publish a plain-language **privacy policy** and **terms of service**.
- Support deleting an account and exporting personal data (GDPR/CCPA basics).
- Know where data lives — some customers require EU or in-country storage.
- If you touch health, payment, or children's data, research the specific rules **before** designing.

### Accessibility (WCAG 2.2)
- Enough color contrast to read in sunlight.
- Everything reachable by keyboard alone.
- Labels on every form field.
- Alt text on meaningful images.
- Never rely on color alone to convey meaning.

Accessible apps are also easier for everyone, and it's far cheaper than retrofitting.

### Documentation that earns its keep
- **README**: how to run the project locally, in under ten minutes.
- **Architecture Decision Records (ADRs)**: one short page per big choice — what we picked, why, what we rejected. Future-you will be grateful.
- **Runbook**: what to do when things break, including who to call.
- **Changelog**: what shipped, when.

### Definition of Done — post this on the wall

Work isn't done until:
1. Code is written and reviewed
2. Tests pass in CI
3. It works on mobile screens
4. Basic accessibility checked
5. Documentation updated
6. Deployed to staging and clicked through by someone else
7. The Product Owner has seen it and agreed

### Monitoring and metrics

Watch **five delivery metrics** (the modern DORA set):
1. **Deployment frequency** — how often you ship
2. **Lead time for changes** — idea to production
3. **Change failure rate** — share of releases that cause problems
4. **Failed deployment recovery time** — how fast you're back to healthy
5. **Rework rate** — how much shipped work has to be redone

Plus: uptime, error rate, page load speed, and product numbers (sign-ups, weekly active users, retention).

The point isn't a scoreboard. It's noticing "our change failure rate doubled this month" before customers notice for you.

### Using AI coding assistants well
- Great for boilerplate, tests, unfamiliar syntax, explaining strange code, first drafts.
- **Review every line.** AI-written code passes review less carefully in most teams — and 2025–2026 industry research links AI adoption to higher throughput but also more instability, bigger pull requests, and more production incidents per change.
- The teams that gain most already had good tests, review, and rollback. AI amplifies whatever your practices already are, good or bad.
- Never paste customer data or secrets into a tool that isn't approved for it.

---

## Part 6: The Full Process, Idea to Maintenance

### Phase 0 — Discovery (1–2 weeks)
**Goal:** be sure the problem is real.
1. Write the one-sentence problem statement.
2. Interview 5–10 potential users. Ask about today, not features.
3. Check what already exists. If a $10/month tool solves it, say so out loud.
4. Define the single measure of success: *"20 workers use it weekly within 3 months."*
5. Decide who it is **not** for. This saves months.

**Exit test:** can every one of the six teammates state the problem in one sentence, the same way?

### Phase 1 — Requirements (3–5 days)
1. List every idea. Everything. No filtering yet.
2. Sort with **MoSCoW**: Must have / Should have / Could have / Won't have.
3. Your **MVP** (minimum viable product) is only the Must-haves. TaskTrack's MVP was five items.
4. Turn Must-haves into user stories with acceptance criteria.
5. Get written agreement from whoever is paying.

**Common mistake:** an MVP with 30 features. That's not an MVP, that's a year.

### Phase 2 — Design (1 week)
1. **User flows**: arrows on a whiteboard showing the path from landing page to core action.
2. **Wireframes**: gray boxes, no colors, fast to change.
3. **Mockups** in Figma with real colors, type, and spacing.
4. Pick a **component library** (shadcn/ui + Tailwind is the 2026 default) so six people build consistent screens without arguing about button radius.
5. Show mockups to 3 users. Watch where they hesitate. Fix that.

### Phase 3 — Technical planning (3–5 days)
1. Choose the stack (use Part 3's tables).
2. Draw the data model — tables and how they link.
3. Sketch the architecture on one page.
4. Decide the deployment path: dev → preview → staging → production.
5. Write your first ADRs.
6. Plan **multi-tenancy** if businesses will be your customers: how do two companies' data stay separated? (Usually a `company_id` column plus RLS.)

### Phase 4 — Setup (3–5 days)
Do all of this **before** feature work, or you'll be doing it during a crisis instead:
1. Repository, branch protection, PR template.
2. Project board with the backlog loaded.
3. All three environments live.
4. CI/CD pipeline green.
5. Authentication working end to end (register, confirm email, log in, log out, reset password).
6. Error tracking and analytics installed.
7. A shared team calendar with your meeting rhythm on it.
8. One "hello world" page deployed to production. Proving the whole pipeline works on day four is worth a great deal of calm later.

### Phase 5 — Build (6–10 weeks in 2-week cycles)

A typical cycle for six people:

| Day | What happens |
|---|---|
| Mon (start) | Planning: pick the work, split it up |
| Daily | 15-minute standup |
| Tue–Thu wk 1 | Build and review |
| Fri wk 1 | Mid-point check: are we on track or overloaded? |
| Mon–Wed wk 2 | Build, review, test |
| Thu wk 2 | Testing day: QA hammers everything, bugs fixed |
| Fri wk 2 | Demo, retrospective, ship |

Build in **vertical slices**: one complete feature, database to screen, working and shipped. Don't build "all the backend" for six weeks — you'll have nothing to show and no idea if it works.

Ship in this order: (1) auth, (2) the single core action, (3) the second-most-important action, (4) admin/reporting, (5) polish.

### Phase 6 — Testing and hardening (1–2 weeks)
1. **Functional**: every acceptance criterion, checked.
2. **Cross-device**: Chrome, Safari, Firefox, real iPhone, real Android.
3. **Load**: simulate 10x your expected users (k6 or Artillery).
4. **Security**: run `npm audit`, try to reach another user's data on purpose, verify RLS actually blocks you.
5. **Accessibility**: keyboard-only pass, screen reader pass, automated axe scan.
6. **Recovery drill**: delete something in staging and restore from backup. An untested backup is a rumor.

### Phase 7 — Beta (1–2 weeks)
1. Invite 5–20 friendly real users.
2. Give them a specific task and watch, quietly. Resist explaining.
3. Collect feedback in one place with an in-app widget.
4. Fix crashes and confusion. Add features only if several people hit the same wall.
5. Write your help docs from the questions beta users actually ask.

### Phase 8 — Launch
**Pre-launch checklist:**
- [ ] Privacy policy and terms published
- [ ] Custom domain with HTTPS
- [ ] Transactional emails working (welcome, password reset, receipts)
- [ ] Payments tested with real cards in Stripe test then live mode
- [ ] Error alerts routing to a channel someone reads
- [ ] Automatic database backups on, and one restore tested
- [ ] Support inbox exists and is monitored
- [ ] Rollback plan written down, not just understood
- [ ] Uptime monitoring with alerts
- [ ] Someone specifically on call for the first 48 hours

**Soft launch first:** open to a small group, watch for a week, then announce widely. Launch on a Tuesday morning, never a Friday afternoon.

### Phase 9 — Maintenance and growth (forever)

**Daily:** check error dashboard, answer support, watch uptime.
**Weekly:** review usage numbers, triage new bugs, merge dependency updates, one-hour team sync on priorities.
**Monthly:** apply security patches, review the cloud bill, check performance trends, plan next month, run a retrospective.
**Quarterly:** revisit the roadmap, interview 5 users again, review your delivery metrics, prune features nobody uses, test the disaster-recovery plan end to end.
**Yearly:** major framework upgrades, renegotiate vendors, revisit architecture decisions in your ADRs.

**Budget guidance:** plan for roughly **20–30% of engineering time on maintenance** — bugs, upgrades, support, and paying down shortcuts. Teams that budget 0% end up at 60% within two years, because unpaid technical debt collects interest.

**Handling incidents:**
1. Stop the bleeding — roll back first, diagnose second.
2. Tell users honestly. Silence is worse than bad news.
3. Fix the root cause.
4. Write a **blameless postmortem**: what happened, why, what changes so it can't happen the same way again. Blame hides information; curiosity surfaces it.

---

## Part 7: Reference

### Who does what, week to week

| Role | Main job | Typical week |
|---|---|---|
| Product Owner | Decides priority, talks to users | Grooms backlog, 3 user calls, approves finished work |
| Team Lead | Keeps flow smooth | Runs standups, unblocks people, shields team from noise |
| Developer 1 (backend-leaning) | Data, APIs, permissions | 2–3 stories, reviews teammates' PRs |
| Developer 2 (full-stack) | Features end to end | 2–3 stories, reviews PRs |
| Designer / Frontend | Screens and usability | Mockups one sprint ahead, builds UI, checks accessibility |
| QA / DevOps | Quality and pipeline | Writes tests, owns CI/CD, monitors production, runs release |

Six people is a **great** size. Everyone fits in one conversation, and there's no need for managers of managers. Guard that: as soon as you need a meeting to decide who attends a meeting, something has gone wrong.

### Ten mistakes that sink small teams
1. **Building for a year before showing anyone.** Ship in weeks.
2. **Skipping the boring setup.** Debugging deployment during a launch is misery.
3. **Building your own authentication.** No.
4. **Ignoring mobile screens.** Most business users check things on a phone.
5. **No tests at all**, then being afraid to change anything.
6. **One person as the only one who understands X.** Rotate; document.
7. **Saying yes to every request.** A product that does everything does nothing well.
8. **Ignoring the cloud bill** until it's a surprise.
9. **Trusting AI-generated code without review.** Speed without stability is a debt, not a gain.
10. **Never talking to users after launch.** The people using it know things you don't.

### Glossary

| Term | Plain meaning |
|---|---|
| **API** | The way two programs talk to each other |
| **Backend** | The hidden part: logic, rules, data |
| **CI/CD** | Robots that check and ship your code automatically |
| **Frontend** | The part users see and click |
| **MVP** | Smallest version that solves the real problem |
| **PR (pull request)** | "Here's my change, please review before it goes in" |
| **RLS** | Database-level rule so users only see their own rows |
| **Sprint** | A fixed short work period, usually 2 weeks |
| **Staging** | Practice copy of the live site |
| **Technical debt** | Shortcuts you took that cost you later |
| **Tenant** | One customer company inside a shared app |
| **WIP limit** | Max number of tasks in progress at once |

### First-week checklist

- [ ] Problem statement written, agreed by all six
- [ ] Roles assigned
- [ ] 5 user interviews booked
- [ ] Shared accounts created (GitHub, cloud, board, chat, password manager)
- [ ] Working agreements written: meeting times, response expectations, Definition of Done
- [ ] Repository created with README and CI
- [ ] "Hello world" deployed to production
- [ ] Backlog seeded with the MVP stories
- [ ] Next two weeks planned

---

*Practices to re-verify before you commit, since tooling moves fast: current framework major versions, current pricing tiers for your auth and hosting vendors, and the latest guidance on AI-assisted development. The principles in this guide are stable; the version numbers are not.*
