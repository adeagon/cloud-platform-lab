# Teardown Checklist

Run at the end of every work session before closing.

[ ] terraform destroy in the eks/ stack
[ ] confirm cluster gone:        aws eks list-clusters
[ ] confirm no orphan LBs:       aws elbv2 describe-load-balancers
[ ] confirm no orphan volumes:   aws ec2 describe-volumes --filters Name=status,Values=available
[ ] confirm NAT gone (if used):  aws ec2 describe-nat-gateways
[ ] glance at Budgets dashboard
