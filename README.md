# BetterBill

Deeper analysis of Amazon CUR.

# Overview

Amazon Cost and Usage Report (CUR) is the latest iteration of AWS cloud usage bills. Its structure has been refactored 
and it contains more data than the previous report formats.

However, it still is a wide columns table with 100s of columns. Every service would overload some columns, making
it very difficult to make unified analysis across services. Lacking of detailed field descriptions and possible
values also means you have to do a lot of trial-and-errors to find out exact semantics of the fields.

BetterBill is my take on the usability of the CUR report. Basically we dissect the wide columns table and make 
alias of fields, so you can tell the meaning of a field just by looking at its name. 

Besides, cost computation is also unified. For example, the way Savings Plans is calculated is very different
from Reserved Instance and On-Demand usage. They have all been unified under the same model, so it is easy to
analyze your usage across SP, RI and On-Demand.

# Features

- Field aliased semantically by service
- Unified cost computation model
- RI, SP tagged by the resources that uses them
  - Leftovers are also marked
- (planned) Data integrity check, so you know the converted cost is correct
- (planned) Usage showcase in Amazon QuickSight, demo of what you can achieve with BetterBill
- (in-dev) A boto3 script for easily bootstrapping / upgrading BetterBill SQL views into Athena