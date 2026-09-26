#!/usr/bin/env python3
"""File or update the Linear drift issue for an upstream bump that didn't land (ENG-483).

Usage: linear_drift_issue.py <old-sha> <new-sha> <report.md>

Drift issues are sub-issues of the Cornerman map (ENG-473) in project `cornerman`, team
Engineering, labelled Improvement. One open issue per target SHA: a rerun against the same
upstream SHA updates the existing issue instead of filing a duplicate. Reads LINEAR_API_KEY
from the environment and never prints it. Standard library only.
"""
import json
import os
import sys
import urllib.request

API = "https://api.linear.app/graphql"
MAP_ISSUE = "ENG-473"
PROJECT = "cornerman"
TEAM_KEY = "ENG"
LABEL = "Improvement"


def gql(query, variables):
    key = os.environ.get("LINEAR_API_KEY")
    if not key:
        sys.exit("linear_drift_issue: LINEAR_API_KEY is not set")
    body = json.dumps({"query": query, "variables": variables}).encode()
    req = urllib.request.Request(
        API, data=body, headers={"Content-Type": "application/json", "Authorization": key}
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        payload = json.load(resp)
    if payload.get("errors"):
        sys.exit(f"linear_drift_issue: Linear API error: {payload['errors']}")
    return payload["data"]


def main():
    old, new, report_path = sys.argv[1:4]
    with open(report_path, encoding="utf-8") as fh:
        description = fh.read()
    title = f"Upstream drift: ringer {old}..{new}"

    ctx = gql(
        """query($map: String!, $team: String!, $project: String!, $label: String!) {
          issue(id: $map) { id }
          teams(filter: {key: {eq: $team}}) { nodes { id
            labels(filter: {name: {eq: $label}}) { nodes { id } } } }
          projects(filter: {name: {eq: $project}}) { nodes { id } }
        }""",
        {"map": MAP_ISSUE, "team": TEAM_KEY, "project": PROJECT, "label": LABEL},
    )
    team = ctx["teams"]["nodes"][0]
    labels = [n["id"] for n in team["labels"]["nodes"]]
    project_id = ctx["projects"]["nodes"][0]["id"]

    existing = gql(
        """query($project: ID!, $sha: String!) {
          issues(filter: {project: {id: {eq: $project}}, title: {contains: $sha},
                          state: {type: {nin: ["completed", "canceled"]}}}) {
            nodes { id identifier url } }
        }""",
        {"project": project_id, "sha": f"..{new}"},
    )["issues"]["nodes"]

    if existing:
        issue = existing[0]
        gql(
            """mutation($id: String!, $title: String!, $description: String!) {
              issueUpdate(id: $id, input: {title: $title, description: $description}) { success }
            }""",
            {"id": issue["id"], "title": title, "description": description},
        )
        print(f"updated {issue['identifier']}: {issue['url']}")
        return

    created = gql(
        """mutation($input: IssueCreateInput!) {
          issueCreate(input: $input) { issue { identifier url } }
        }""",
        {
            "input": {
                "teamId": team["id"],
                "projectId": project_id,
                "parentId": ctx["issue"]["id"],
                "labelIds": labels,
                "title": title,
                "description": description,
            }
        },
    )["issueCreate"]["issue"]
    print(f"filed {created['identifier']}: {created['url']}")


if __name__ == "__main__":
    main()
