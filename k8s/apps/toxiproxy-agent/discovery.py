import fnmatch
import re
from dataclasses import dataclass
from typing import Optional

from kubernetes import client
from kubernetes import config as k8s_config
from kubernetes.client.rest import ApiException


@dataclass
class ServiceInfo:
    name: str
    namespace: str
    cluster_ip: str
    port: int

    @property
    def dns_name(self) -> str:
        return f"{self.name}.{self.namespace}.svc"

    @property
    def address(self) -> str:
        return f"{self.dns_name}:{self.port}"


@dataclass
class DataPlaneInfo:
    namespace: str
    index: int
    redis: Optional[ServiceInfo] = None
    gateway: Optional[ServiceInfo] = None


@dataclass
class ControlPlaneInfo:
    namespace: str
    dashboard: Optional[ServiceInfo] = None
    gateway: Optional[ServiceInfo] = None
    mdcb: Optional[ServiceInfo] = None
    redis: Optional[ServiceInfo] = None
    mongo: Optional[ServiceInfo] = None


class K8sDiscovery:
    def __init__(self, kubeconfig: Optional[str] = None, context: Optional[str] = None):
        try:
            if kubeconfig:
                k8s_config.load_kube_config(config_file=kubeconfig, context=context)
            else:
                try:
                    k8s_config.load_incluster_config()
                except k8s_config.ConfigException:
                    k8s_config.load_kube_config(context=context)
        except Exception as e:
            raise RuntimeError(f"Failed to load Kubernetes configuration: {e}")

        self.core_api = client.CoreV1Api()

    def discover_namespaces(self, pattern: str = "tyk-dp-*") -> list[str]:
        try:
            namespaces = self.core_api.list_namespace()
            matching = [
                ns.metadata.name
                for ns in namespaces.items
                if fnmatch.fnmatch(ns.metadata.name, pattern)
            ]
            return sorted(matching, key=self._extract_dp_index)
        except ApiException as e:
            raise RuntimeError(f"Failed to list namespaces: {e}")

    def _extract_dp_index(self, namespace: str) -> int:
        match = re.search(r"tyk-dp-(\d+)", namespace)
        return int(match.group(1)) if match else 0

    def _find_service(
        self, namespace: str, name: str, default_port: int = 0
    ) -> Optional[ServiceInfo]:
        try:
            svc = self.core_api.read_namespaced_service(name=name, namespace=namespace)
            port = default_port
            if svc.spec.ports:
                port = svc.spec.ports[0].port
            return ServiceInfo(
                name=svc.metadata.name,
                namespace=namespace,
                cluster_ip=svc.spec.cluster_ip or "",
                port=port,
            )
        except ApiException:
            return None

    def _find_service_by_label(
        self, namespace: str, label_selector: str, default_port: int = 0
    ) -> Optional[ServiceInfo]:
        try:
            services = self.core_api.list_namespaced_service(
                namespace=namespace, label_selector=label_selector
            )
            if services.items:
                svc = services.items[0]
                port = default_port
                if svc.spec.ports:
                    port = svc.spec.ports[0].port
                return ServiceInfo(
                    name=svc.metadata.name,
                    namespace=namespace,
                    cluster_ip=svc.spec.cluster_ip or "",
                    port=port,
                )
        except ApiException:
            pass
        return None

    def discover_data_planes(
        self, namespace_pattern: str = "tyk-dp-*"
    ) -> list[DataPlaneInfo]:
        namespaces = self.discover_namespaces(namespace_pattern)
        data_planes = []

        for ns in namespaces:
            index = self._extract_dp_index(ns)
            dp = DataPlaneInfo(namespace=ns, index=index)

            dp.redis = self._find_service_by_label(
                ns, "tyk.io/component=redis", default_port=6379
            )
            dp.gateway = self._find_service_by_label(
                ns, "tyk.io/component=gateway", default_port=8080
            )

            data_planes.append(dp)

        return data_planes

    def discover_control_plane(self, namespace: str = "tyk") -> ControlPlaneInfo:
        cp = ControlPlaneInfo(namespace=namespace)

        cp.dashboard = self._find_service_by_label(
            namespace, "tyk.io/component=dashboard", default_port=3000
        )
        cp.gateway = self._find_service_by_label(
            namespace, "tyk.io/component=gateway", default_port=8080
        )
        cp.mdcb = self._find_service_by_label(
            namespace, "tyk.io/component=mdcb", default_port=9091
        )
        cp.redis = self._find_service_by_label(
            namespace, "tyk.io/component=redis", default_port=6379
        )
        cp.mongo = self._find_service_by_label(
            namespace, "tyk.io/component=mongo", default_port=27017
        )

        return cp

    def patch_toxiproxy_service(
        self,
        namespace: str,
        service_name: str,
        proxy_ports: list[tuple[str, int]],
    ) -> None:
        ports = [{"name": "api", "port": 8474, "targetPort": 8474, "protocol": "TCP"}]
        for name, port in proxy_ports:
            ports.append(
                {
                    "name": name,
                    "port": port,
                    "targetPort": port,
                    "protocol": "TCP",
                }
            )

        patch = {"spec": {"ports": ports}}
        try:
            self.core_api.patch_namespaced_service(
                name=service_name,
                namespace=namespace,
                body=patch,
            )
        except ApiException as e:
            raise RuntimeError(f"Failed to patch ToxiProxy Service: {e}")
