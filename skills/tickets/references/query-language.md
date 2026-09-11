# The free text after the command

Everything is optional. With no free text the answer is *my open tickets, everywhere, by priority*.

## What the filter narrows, and what it does not

It narrows **tickets**. Your open pull requests are always shown, because a pull request you owe is
owed whatever the filter says — a sprint or priority label lives on a ticket, not on a branch, and a
pull request with no ticket at all would vanish from a filtered answer precisely when it still needs
you. The one qualifier that carries over is `OWNER/REPOSITORY`: that one is about where you are
working, not about which tickets matched.

The vocabulary is closed and small on purpose. A small parser that reports what it did not
understand beats a clever one that quietly guesses — the failure mode of a guess here is a short,
plausible, wrong table.

## What it recognizes

| Words | Effect |
| --- | --- |
| `s4`, `S4`, `sprint 4`, `sprint-4` | sprint label `sprint-4`; several sprints combine as *or* |
| `p0`, `p1`, `p2`, `p3` | priority label; `urgent`/`critical` → P0, `high` → P1, `medium` → P2, `low` → P3; several combine as *or* |
| `closed`, `done`, `finished` | closed tickets instead of open ones |
| `open`, `active` | open tickets (the default) |
| `all`, `any`, `everything` | both |
| `epics`, `parents` | only parent tickets |
| `no epics`, `without epics`, `leaf` | drop parent tickets |
| `blocked` | only tickets with an open dependency |
| `OWNER/REPOSITORY`, `repo:OWNER/REPOSITORY` | narrow to that repository; several combine as *or* |
| `label:NAME` | require that label |
| `@LOGIN`, `assignee:LOGIN` | somebody else's tickets |

Ignored as filler: `of`, `only`, `my`, `the`, `in`, `for`, `me`, `show`, `list`, `please`,
`ticket(s)`, `issue(s)`. So `only closed tickets of s4` and `closed s4` are the same request.

Different kinds of filter combine as *and*: `closed s4 p1` means closed **and** sprint-4 **and**
P1-high. Repetitions of one kind combine as *or*: `p0 p1` means P0 **or** P1.

## What it does not

Any other word becomes a title-and-body search term **and** is echoed in `.filter.unparsed`. That
list is not diagnostic noise — report it. `tickets about the seeding bug` searches for
`seeding bug` and says so, which lets the user see the difference between a filter and a guess.

There is no date range, no sort override, no field selection. Those belong in the tracker's own
search, and inventing a half-implementation of them here would be the worst of both.

## Sprint labels versus sprint titles

The **label** is authoritative. Titles often carry a sprint prefix that has gone stale after
re-planning — a ticket titled `S4/P1: …` and labelled `sprint-5` belongs to sprint 5. A ticket with
no sprint label at all falls back to its title prefix, which is better than an empty cell.

## Examples

| Request | Means |
| --- | --- |
| *(nothing)* | my open tickets, all repositories, by priority |
| `of s4` | my open sprint-4 tickets |
| `only closed tickets of s4` | my closed sprint-4 tickets |
| `p0 p1` | my open urgent and high tickets |
| `blocked s4` | my open sprint-4 tickets with an open dependency |
| `epics of s4` | my open sprint-4 parent tickets |
| `all of s4 no epics` | my sprint-4 leaf tickets, open and closed |
| `s4 OWNER/REPOSITORY` | my open sprint-4 tickets in that one repository |
