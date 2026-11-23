<!-- jcouball-github guardrails: begin sha256:7976bde10498 -->
Never commit or push to `main`. Create a topic branch
first (`git switch -c <type>/<short-description>`) and open a pull
request instead.
<!-- jcouball-github guardrails: end -->

Before changing a script, a template, or a data file a script reads, read
`TESTING.md`. It says how to test the change on sophon without changing the
machine, and which pull request lists the cases each script was tested with.

A pull request does not need a certification run to merge. It needs review and
evidence that the change itself works, tested as `TESTING.md` says. Say in the
pull request what was done.

Certification comes after the merge. `main` is certified when there is
something on it that a rebuild should get, and one run can cover several
merged changes. "Re-certify the rebuild" in the README says what needs a run
before it reaches `stable`, the branch a rebuild clones, and what does not. A
run takes about an hour, so a branch run before the merge is for a new
provisioning script or a change to the rebuild's own commands, once, after
review.

Certifying and recording happen on sophon (`ssh sophon`), whose chezmoi source
follows `main`. `recertify.ps1` and `record.ps1` can both be run over ssh.
Never report a run that did not happen. Nothing but `record.ps1` pushes to
`stable`.
