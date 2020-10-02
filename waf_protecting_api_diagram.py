from diagrams import Cluster, Diagram, Edge
from diagrams.onprem.client import User

from diagrams.gcp.compute import Run
from diagrams.gcp.devtools import Build
from diagrams.onprem.vcs import Github

graph_attr = {
    "pad": "0"
}

with Diagram("Vulnerable API protected", graph_attr=graph_attr) as waf_diagram:
    github_1 = Github("GitHub repo")

    with Cluster("API project"):
        build = Build("Cloud Build")

        waf = Run("WAF")
        api = Run("API")

    user = User("Hacker")

    github_1 >> Edge(label="Build Trigger", color="black") >> build >> Edge(label="Deploy", style="dotted") >> waf
    build >> Edge(label="Deploy", style="dotted") >> api
    waf - Edge() - api
    user - Edge(label="https") - waf
