# Mission Telemetry Domain

This context defines the language for recording and comparing DCS mission
activity. It deliberately separates combat results from economic estimates.

## Runs And Participants

**Mission Run**:
A single loaded execution of a DCS mission, from mission start until the
mission ends or is restarted. A restart creates a new run with no inherited
state, and the run is the initial historical boundary for captured statistics.
_Avoid_: Match, campaign, session

**Participant**:
A human pilot taking part in a mission run. A participant has one stable
identity and may appear under different display names or callsigns over time.
_Avoid_: Player, user, account

**Coalition**:
A DCS side participating in a mission run. The initial scoreboard compares
coalition outcomes and costs.
_Avoid_: Team, faction

**Sortie**:
A participant's period of controlling an aircraft during a mission run.
_Avoid_: Flight, round

**Asset Instance**:
One identifiable military-entity incarnation during a mission run, such as an
aircraft, vehicle, ship, or AI-controlled entity. Reuse of a DCS name does not
make a replacement the same asset instance.
_Avoid_: Unit, platform

**Tracked Asset Scope**:
The explicit boundary of asset categories included in a telemetry release.
Assets outside this boundary are intentionally excluded rather than unknown.
_Avoid_: Everything, all world objects

## Events And Outcomes

**Mission Event**:
A recorded occurrence in a mission run involving one or more participants,
assets, ordnance items, or coalitions.
_Avoid_: Log line, statistic

**Source Event**:
A mission event as reported by DCS or a telemetry source, preserved even when
another source event may describe the same occurrence.
_Avoid_: Raw event, duplicate event

**Derived Fact**:
A canonical interpretation of one or more source events used for statistics,
such as one aircraft loss derived from several loss signals.
_Avoid_: Cleaned event, aggregate

**Event Deduplication**:
The interpretation that several source events may describe one occurrence and
must produce one derived fact without discarding the source events.
_Avoid_: Event deletion, log cleanup

**Aircraft Loss**:
An aircraft crash or destruction. It incurs aircraft replacement cost even when
the pilot ejects and survives.
_Avoid_: Pilot loss, sortie loss

**Kill**:
The destruction of an asset attributed to one primary attacker when attribution
is available.
_Avoid_: Death, takedown

**Assist**:
A participant's qualifying contribution to the destruction of an asset without
being its primary killer.
_Avoid_: Shared kill, partial kill

**Unknown Attribution**:
A recorded outcome for which the responsible attacker cannot be identified.
_Avoid_: Player, default attacker

**Combat Standing**:
A live comparison of coalition combat effectiveness that may show one side
ahead, behind, tied, or undetermined without ending the mission. The initial
duel standing uses aircraft kill differential.
_Avoid_: Terminal winner, match result

## Accounting

**Ordnance Expenditure**:
A discrete weapon firing event. The expenditure is incurred when the weapon is
fired, regardless of whether it later hits or causes a kill.
_Avoid_: Hit, impact, ammunition loss

**Valuation Catalogue**:
A versioned set of one selected estimated USD value for each ordnance or asset,
including the source or rationale for the estimate.
_Avoid_: Price list, market price

**Mission Cost**:
The sum of valued ordnance expenditures and asset losses using the catalogue
assigned to the mission run. If any included item is unpriced, the known
subtotal is explicitly partial rather than treating that item as zero-cost.
_Avoid_: Score, budget

**Cost Efficiency**:
A comparison between a combat outcome and the cost incurred to achieve it.
_Avoid_: Cheap win, economic score

**Scoreboard**:
A view of mission outcomes grouped by coalition, participant, asset, or event
category. Cost and combat effectiveness are separate dimensions.
_Avoid_: Ranking, leaderboard

## Data Policy

**Mission Run Status**:
A run-lifecycle label: active, completed, or aborted. A stale heartbeat is an
operational warning, not a final run status.
_Avoid_: Deleted test, temporary run

**Run Classification**:
A label distinguishing test runs from runs intended for historical results.
Both classifications are retained and can be filtered independently of run
status.
_Avoid_: Run status, deleted test

**Initial Visibility**:
The first dashboard version is publicly viewable without user authentication;
writing mission data still requires a collector credential.
_Avoid_: Private dashboard, player login
