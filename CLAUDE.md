<!-- jcouball-github guardrails: begin sha256:7976bde10498 -->
Never commit or push to `main`. Create a topic branch
first (`git switch -c <type>/<short-description>`) and open a pull
request instead.
<!-- jcouball-github guardrails: end -->

Before changing a script, a template, or a data file a script reads, read
`TESTING.md`. It says how to test the change on sophon without changing the
machine, and which pull request lists the cases each script was tested with.
