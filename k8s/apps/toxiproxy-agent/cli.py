#!/usr/bin/env python3
"""
tyk-toxiproxy CLI - Dynamic Toxiproxy configuration for Tyk K8s resilience testing.

Usage:
    python cli.py configure --toxiproxy-url http://localhost:8474 --output-env shell
"""

import json
import time
from dataclasses import dataclass, field
from typing import Optional
from urllib.parse import urlparse

import yaml
import typer
from discovery import ControlPlaneInfo, DataPlaneInfo, K8sDiscovery, NamespacePorts
from rich.console import Console
from toxiproxy import Toxiproxy

app = typer.Typer(
    name="tyk-toxiproxy",
    help="Dynamic Toxiproxy configuration for Tyk K8s resilience testing.",
    no_args_is_help=True,
    add_completion=False,
)
configure_app = typer.Typer()
app.add_typer(configure_app, name="configure")

console = Console()
err_console = Console(stderr=True)


@dataclass
class ProxyConfig:
    name: str
    listen: str
    upstream: str
    enabled: bool = True

    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "listen": self.listen,
            "upstream": self.upstream,
            "enabled": self.enabled,
        }


@dataclass
class ToxiproxyConfig:
    proxies: list[ProxyConfig] = field(default_factory=list)

    def to_list(self) -> list[dict]:
        return [p.to_dict() for p in self.proxies]

    def get_port_mappings(self) -> list[tuple[str, int]]:
        result = []
        for proxy in self.proxies:
            port = int(proxy.listen.split(":")[-1])
            result.append((proxy.name, port))
        return result


BASE_REDIS_DP_PORT = 7379


def build_proxy_config(
    cp: ControlPlaneInfo,
    data_planes: list[DataPlaneInfo],
    version: str,
    ports: NamespacePorts,
) -> ToxiproxyConfig:
    proxies = []

    if cp.dashboard:
        proxies.append(
            ProxyConfig(
                name=f"dashboard-{version}",
                listen=f"[::]:{ports.dashboard}",
                upstream=cp.dashboard.address,
            )
        )
    if cp.gateway:
        proxies.append(
            ProxyConfig(
                name=f"cp-gateway-{version}",
                listen=f"[::]:{ports.gateway}",
                upstream=cp.gateway.address,
            )
        )
    if cp.mdcb:
        proxies.append(
            ProxyConfig(
                name=f"mdcb-{version}",
                listen=f"[::]:{ports.mdcb}",
                upstream=cp.mdcb.address,
            )
        )
    if cp.redis:
        proxies.append(
            ProxyConfig(
                name=f"redis-cp-{version}",
                listen=f"[::]:{ports.redis_cp}",
                upstream=cp.redis.address,
            )
        )
    if cp.mongo:
        proxies.append(
            ProxyConfig(
                name=f"mongo-{version}",
                listen=f"[::]:{ports.mongo}",
                upstream=cp.mongo.address,
            )
        )

    for dp in data_planes:
        if dp.redis:
            port = dp.ports.redis if dp.ports else BASE_REDIS_DP_PORT + (dp.index * 1000)
            proxies.append(
                ProxyConfig(
                    name=f"redis-dp-{dp.index}-{version}",
                    listen=f"[::]:{port}",
                    upstream=dp.redis.address,
                )
            )

    return ToxiproxyConfig(proxies=proxies)


def build_predictive_proxy_config(
    topology: str,
    ports: dict,
    num_data_planes: int,
    toxiproxy_namespace: str,
) -> ToxiproxyConfig:
    """
    Build proxy configuration from ports file without K8s discovery.

    Uses predictable K8s DNS naming:
    - CP services: {service}.{cp_namespace}.svc:{original_port}
    - DP services: {service}.{dp_namespace}.svc:{original_port}
    """
    cp_namespace = f"tyk-{topology}"
    proxies = []

    # Control Plane Redis: simple-redis chart creates service named "redis"
    proxies.append(ProxyConfig(
        name=f"redis-cp-{topology}",
        listen=f"[::]:{ports['redisCP']}",
        upstream=f"redis.{cp_namespace}.svc:6379",
    ))

    # MongoDB: inline manifest creates service named "mongo"
    proxies.append(ProxyConfig(
        name=f"mongo-{topology}",
        listen=f"[::]:{ports['mongo']}",
        upstream=f"mongo.{cp_namespace}.svc:27017",
    ))

    # MDCB: tyk-control-plane chart creates service with this naming pattern
    proxies.append(ProxyConfig(
        name=f"mdcb-{topology}",
        listen=f"[::]:{ports['mdcb']}",
        upstream=f"mdcb-svc-tyk-control-plane-{topology}-tyk-mdcb.{cp_namespace}.svc:9091",
    ))

    # Dashboard
    proxies.append(ProxyConfig(
        name=f"dashboard-{topology}",
        listen=f"[::]:{ports['dashboard']}",
        upstream=f"dashboard-svc-tyk-control-plane-{topology}-tyk-dashboard.{cp_namespace}.svc:3000",
    ))

    # CP Gateway
    proxies.append(ProxyConfig(
        name=f"cp-gateway-{topology}",
        listen=f"[::]:{ports['gateway']}",
        upstream=f"gateway-svc-tyk-control-plane-{topology}-tyk-gateway.{cp_namespace}.svc:8080",
    ))

    # Data Plane Redis
    for i in range(1, num_data_planes + 1):
        dp_namespace = f"tyk-{topology}-dp-{i}"
        port_key = f"redisDp{i}"
        proxies.append(ProxyConfig(
            name=f"redis-dp-{i}-{topology}",
            listen=f"[::]:{ports[port_key]}",
            upstream=f"redis.{dp_namespace}.svc:6379",
        ))

    return ToxiproxyConfig(proxies=proxies)


def generate_env_vars(
    toxiproxy_url: str, data_planes: list[DataPlaneInfo]
) -> dict[str, str]:
    env_vars = {
        "TOXIPROXY_URL": toxiproxy_url,
        "TYK_TEST_BASE_URL": "http://chart-dash.test/",
        "TYK_TEST_GW_URL": "http://chart-gw.test/",
        "TYK_TEST_GW_SECRET": "352d20ee67be67f6340b4c0605b044b7",
    }
    for dp in data_planes:
        env_vars[f"TYK_TEST_GW_{dp.index}_ALFA_URL"] = (
            f"http://chart-gw-dp-{dp.index}.test/"
        )
    return env_vars


def generate_hosts_entries(data_planes: list[DataPlaneInfo]) -> list[str]:
    entries = [
        "127.0.0.1 chart-dash.test",
        "127.0.0.1 chart-gw.test",
        "127.0.0.1 chart-mdcb.test",
    ]
    for dp in data_planes:
        entries.append(f"127.0.0.1 chart-gw-dp-{dp.index}.test")
    return entries


def format_shell_env(env_vars: dict[str, str]) -> str:
    return "\n".join(f'export {k}="{v}"' for k, v in sorted(env_vars.items()))


def format_github_actions_env(env_vars: dict[str, str]) -> str:
    return "\n".join(f"{k}={v}" for k, v in sorted(env_vars.items()))


def create_toxiproxy_client(url: str) -> Toxiproxy:
    parsed = urlparse(url)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 8474
    client = Toxiproxy()
    client.update_api_consumer(host, port)
    return client


def wait_for_toxiproxy(client: Toxiproxy, timeout: int = 30) -> bool:
    start = time.time()
    while time.time() - start < timeout:
        try:
            if client.running():
                return True
        except Exception:
            pass
        time.sleep(1)
    return False


def _build_configmap_entry(
    version: str,
    config: ToxiproxyConfig,
    data_planes: list,
) -> dict:
    suffix = f"-{version}"
    cp_proxies: dict[str, str] = {}
    dp_redis_proxies: dict[int, str] = {}

    for proxy in config.proxies:
        if not proxy.name.endswith(suffix):
            continue
        logical = proxy.name[: -len(suffix)]
        if logical.startswith("redis-dp-"):
            try:
                index = int(logical.split("-")[-1])
                dp_redis_proxies[index] = proxy.name
            except ValueError:
                pass
        else:
            cp_proxies[logical] = proxy.name

    dp_list = [
        {
            "index": dp.index,
            "namespace": dp.namespace,
            "redisProxy": dp_redis_proxies.get(dp.index, ""),
        }
        for dp in data_planes
    ]
    return {"cpProxies": cp_proxies, "dataPlanes": dp_list}


def write_installation_configmap(
    version: str,
    cp_proxies: dict,
    data_planes: list,
    core_api,
    toxiproxy_namespace: str,
) -> None:
    from kubernetes import client as k8s_client
    from kubernetes.client.rest import ApiException

    cm_name = "toxiproxy-installations"
    entry = json.dumps({"cpProxies": cp_proxies, "dataPlanes": data_planes})

    try:
        cm = core_api.read_namespaced_config_map(name=cm_name, namespace=toxiproxy_namespace)
        patch = {"data": {**(cm.data or {}), version: entry}}
        core_api.patch_namespaced_config_map(
            name=cm_name, namespace=toxiproxy_namespace, body=patch
        )
    except ApiException as e:
        if e.status == 404:
            new_cm = k8s_client.V1ConfigMap(
                metadata=k8s_client.V1ObjectMeta(name=cm_name, namespace=toxiproxy_namespace),
                data={version: entry},
            )
            core_api.create_namespaced_config_map(namespace=toxiproxy_namespace, body=new_cm)
        else:
            raise RuntimeError(f"Failed to write ConfigMap: {e}")


@configure_app.callback(invoke_without_command=True)
def configure(
    toxiproxy_url: str = typer.Option(
        "http://localhost:8474",
        "--toxiproxy-url",
        "-t",
        help="Toxiproxy API URL",
    ),
    namespace_pattern: str = typer.Option(
        "tyk-*-dp-*",
        "--namespace-pattern",
        "-n",
        help="Glob pattern for data plane namespaces (e.g. tyk-lts-dp-*)",
    ),
    control_namespace: str = typer.Option(
        "tyk-lts",
        "--control-namespace",
        "-c",
        help="Control plane namespace (e.g. tyk-lts, tyk-stable, tyk-master)",
    ),
    toxiproxy_namespace: str = typer.Option(
        "toxiproxy",
        "--toxiproxy-namespace",
        "-x",
        help="Toxiproxy namespace (where toxiproxy service is deployed)",
    ),
    ports_file: Optional[str] = typer.Option(
        None,
        "--ports-file",
        "-p",
        help="Path to .ports.yaml file. When provided, skips K8s discovery and uses predictive DNS names.",
    ),
    topology: Optional[str] = typer.Option(
        None,
        "--topology",
        help="Topology name (e.g., lts, stable, master). Required with --ports-file.",
    ),
    num_data_planes: Optional[int] = typer.Option(
        None,
        "--num-data-planes",
        "-d",
        help="Number of data planes. Required with --ports-file.",
    ),
    output_env: Optional[str] = typer.Option(
        None,
        "--output-env",
        "-o",
        help="Output format: shell, github-actions",
    ),
    output_hosts: bool = typer.Option(
        False,
        "--output-hosts",
        help="Output /etc/hosts entries only",
    ),
    verbose: bool = typer.Option(
        False,
        "--verbose",
        "-v",
        help="Enable verbose output",
    ),
):
    try:
        # Validate predictive mode inputs
        if ports_file:
            if not topology:
                err_console.print("[red]--topology is required when using --ports-file[/red]")
                raise typer.Exit(1)
            if not num_data_planes:
                err_console.print("[red]--num-data-planes is required when using --ports-file[/red]")
                raise typer.Exit(1)

        # Build config: predictive or discovery mode
        if ports_file:
            # PREDICTIVE MODE: Read ports file, build from naming conventions
            if verbose:
                err_console.print(f"[blue]Reading ports from {ports_file}...[/blue]")

            with open(ports_file, "r") as f:
                ports = yaml.safe_load(f)

            config = build_predictive_proxy_config(
                topology=topology,
                ports=ports,
                num_data_planes=num_data_planes,
                toxiproxy_namespace=toxiproxy_namespace,
            )

            # For env vars and other outputs, construct synthetic data plane info
            data_planes = [
                DataPlaneInfo(namespace=f"tyk-{topology}-dp-{i}", index=i)
                for i in range(1, num_data_planes + 1)
            ]
            version = topology

            if verbose:
                err_console.print(f"[green]Built predictive config with {len(config.proxies)} proxies[/green]")
        else:
            # DISCOVERY MODE: Existing behavior
            if verbose:
                err_console.print("[blue]Discovering Kubernetes services...[/blue]")

            discovery = K8sDiscovery()
            control_plane = discovery.discover_control_plane(control_namespace)
            data_planes = discovery.discover_data_planes(namespace_pattern)

            if verbose:
                err_console.print(f"[green]Found {len(data_planes)} data plane(s)[/green]")

            version = discovery.get_version(control_namespace)
            cp_ports = discovery.get_namespace_ports(control_namespace)
            for dp in data_planes:
                dp.ports = discovery.get_dp_namespace_ports(dp.namespace)

            config = build_proxy_config(control_plane, data_planes, version, cp_ports)

        if output_hosts:
            console.print("\n".join(generate_hosts_entries(data_planes)))
            return

        if verbose:
            err_console.print(
                f"[blue]Connecting to toxiproxy at {toxiproxy_url}...[/blue]"
            )

        client = create_toxiproxy_client(toxiproxy_url)
        if not wait_for_toxiproxy(client):
            err_console.print("[red]ERROR: Toxiproxy not ready[/red]")
            raise typer.Exit(1)

        if verbose:
            err_console.print(
                f"[green]Connected to toxiproxy {client.version()}[/green]"
            )

        client.populate(config.to_list())

        if verbose:
            err_console.print(
                f"[green]Configured {len(config.proxies)} proxies[/green]"
            )

        # Patch Toxiproxy service - need K8s access for this
        try:
            # Reuse discovery instance for service patching even in predictive mode
            discovery = K8sDiscovery()
            discovery.patch_toxiproxy_service(
                namespace=toxiproxy_namespace,
                service_name="toxiproxy",
                proxy_ports=config.get_port_mappings(),
            )
        except Exception as e:
            if verbose:
                err_console.print(
                    f"[yellow]Warning: Failed to patch Service: {e}[/yellow]"
                )

        try:
            cm_entry = _build_configmap_entry(version, config, data_planes)
            discovery_for_cm = K8sDiscovery()
            write_installation_configmap(
                version=version,
                cp_proxies=cm_entry["cpProxies"],
                data_planes=cm_entry["dataPlanes"],
                core_api=discovery_for_cm.core_api,
                toxiproxy_namespace=toxiproxy_namespace,
            )
            if verbose:
                err_console.print(
                    f"[green]Updated toxiproxy-installations ConfigMap for {version}[/green]"
                )
        except Exception as e:
            if verbose:
                err_console.print(
                    f"[yellow]Warning: Failed to write ConfigMap: {e}[/yellow]"
                )

        if output_env:
            env_vars = generate_env_vars(toxiproxy_url, data_planes)
            if output_env == "shell":
                # Use standard print for reliable stdout redirection in CI
                print(format_shell_env(env_vars), flush=True)
            elif output_env == "github-actions":
                # Use standard print for reliable stdout redirection in CI
                print(format_github_actions_env(env_vars), flush=True)
            else:
                err_console.print(f"[red]Unknown format: {output_env}[/red]")
                raise typer.Exit(1)

    except Exception as e:
        err_console.print(f"[red]Error: {e}[/red]")
        raise typer.Exit(1)


if __name__ == "__main__":
    app()
