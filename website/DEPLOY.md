# Putting the Filo site on a real URL (Vercel)

Plain-language, start to finish. You do the clicking; nothing here needs code.

**Before you start, read [The two decisions](#the-two-decisions-only-you-can-make)
at the bottom.** One of them is about the waitlist telling people something
that isn't true yet. It's a two-minute read and it's the only part that matters
more than the setup.

---

## The one rule this all protects

`website/site/` is the site. Everything else in `website/` — the design
prototypes, the screenshots, the playbook — is internal.

**A web host serves every file in the folder you point it at.** Point Vercel at
the wrong folder and `filo.vercel.app/design-source/project/Home.dc.html` is a
real, public page. So the GitHub repo that Vercel reads is set up to contain the
site *only* — nothing internal is even there to leak.

That's what `publish.sh` is for: it copies `website/site/` up to GitHub and
refuses to run if anything internal sneaks into the set. You never push to that
repo by hand.

---

## Step 1 — Publish the site folder to GitHub

From the repo root, in Terminal:

```bash
./website/publish.sh
```

It prints the exact list of files that will become public, asks you to confirm,
then pushes. **Read that list before typing `y`** — it should be seven or eight
files: three `.html`, `css/filo.css`, three `js/*.js`, `vercel.json`,
`favicon.svg`. If you see anything with `design-source` in the name, type `n`
and tell me.

This overwrites the `filo-website` repo on GitHub with the current site. That's
intentional — that repo is a copy for the host, and this repo is the original.

> The repo is currently holding a **stale July snapshot** that still has
> `design-source/` sitting at its root. Step 1 replaces it. Do not connect
> Vercel before running step 1.

## Step 2 — Make a Vercel account

1. Go to **vercel.com** and click **Sign Up**.
2. Choose **Continue with GitHub** — it's the same login you already use, and it
   saves wiring up permissions later.
3. When it asks what you're doing, pick the **Hobby** (free) plan for now. See
   [decision 2](#2-hobby-or-pro) below.

## Step 3 — Connect the repo

1. On the Vercel dashboard, click **Add New… → Project**.
2. It lists your GitHub repos. Find **`filo-website`** and click **Import**.
   - If it isn't listed, click **Adjust GitHub App Permissions** and give Vercel
     access to that one repo. Don't grant it access to all repos — the app's
     source doesn't need to be on a web host.
3. On the configuration screen:

   | Field | What to set |
   |---|---|
   | **Framework Preset** | **Other** |
   | **Root Directory** | leave blank (`./`) |
   | **Build Command** | leave blank |
   | **Output Directory** | leave blank |
   | **Install Command** | leave blank |
   | **Environment Variables** | none |

   Everything blank is correct. There is no build step — these are plain files
   and Vercel just serves them.
4. Click **Deploy**. It takes about twenty seconds.

You'll get a URL like `filo-website.vercel.app`. That's live, on the public
internet, right now.

## Step 4 — Check it

Open the URL and click through all three pages:

- The **hero popup** should loop through four files (invoice → doc → screenshot → zip).
- Scrolling past the hero should run the **chaos-to-calm** animation and the
  "% sorted" meter.
- **How it works** and **Privacy** should load from the nav.
- The little **gradient square** should show in the browser tab.

Notice the addresses have no `.html` on them — `/how-it-works`, not
`/how-it-works.html`. That's a setting in `vercel.json`; the old `.html`
addresses still work and just redirect, so nothing you've shared breaks.

## Step 5 — Later changes

Tell me what to change, I edit `website/site/`, and then you run:

```bash
./website/publish.sh
```

Vercel notices the push and rebuilds by itself, usually inside a minute. There's
no separate deploy step and nothing to remember.

---

## The two decisions only you can make

### 1. The waitlist doesn't collect anything

Right now the form shows **"Thanks — you're on the list"** and then throws the
address away. There's no service behind it. That was fine as an unpublished
preview; on a public URL, it means telling real people they've signed up for
something when they haven't. It also means every visitor you send there is lost.

Three ways to go:

| Option | What it means |
|---|---|
| **A. Ship it honestly** — I change the button and copy to something true, like a "Coming soon, follow along" line with no email field. | Free, ten minutes, no vendor. Nothing collected — so no early-access list either. |
| **B. Wire a real waitlist first**, then deploy. | Needs a vendor account and probably **costs money** — so it needs your explicit go-ahead. A privacy-first product should pick carefully: an EU-hosted, no-tracking form service, not a marketing suite that starts profiling your signups. |
| **C. Deploy as-is, knowing the form is a placeholder.** | Fastest, and fine if the URL is only for showing people privately. Not fine once it's public and indexed by Google. |

I'd deploy with **A** now and do **B** when Phase 2 (demo video + waitlist)
actually starts — the roadmap already puts the waitlist there. But it's your
call and I haven't changed the copy.

### 2. Hobby or Pro

Vercel's **Hobby** plan is free, and technically it's for non-commercial use —
their terms reserve commercial projects for **Pro at $20/month**. A pre-launch
marketing site with no product to sell is a genuine grey area, and plenty of
startups sit on Hobby until they charge for something. I'm flagging it rather
than deciding it. Start free; know the bill exists.

**A custom domain** (`filo.app` or similar) also costs money — roughly
$10–40/year depending on the name. Vercel can register it or you can point one
you already own. Either way it's a spend, so it waits for you to say yes.

---

## If something goes wrong

| What you see | What it is |
|---|---|
| **404 on the home page** | Root Directory got set to something. Vercel → project → Settings → Build & Deployment → clear it to `./`. |
| **Page loads but is unstyled / animations dead** | `css/filo.css` or `js/*.js` didn't get pushed. Re-run `publish.sh` and read the file list. |
| **`publish.sh` says "uncommitted changes"** | Correct behaviour — the site was edited but not committed yet. Ask me to commit. |
| **`publish.sh` says "Internal files reached the publish set"** | The safety gate fired. Don't work around it; tell me. |
| **A design-source URL loads on the live site** | Take the site down (Vercel → Settings → **Delete Project**) and tell me. This shouldn't be reachable. |

---

**Related:** [README.md](README.md) · [Web-Team-Playbook.md](Web-Team-Playbook.md)
(gate 3 is going live) · [../docs/open-work.md](../docs/open-work.md)
