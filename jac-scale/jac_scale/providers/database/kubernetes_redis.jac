"""Kubernetes Redis provider implementation."""

import hashlib;
import logging;
import from pathlib { Path }
import from typing { Any }
import from jac_scale.abstractions.database_provider { DatabaseProvider }
import from jac_scale.abstractions.deployment_target { DeploymentTarget }
import from jac_scale.config_loader { get_scale_config }

glob logger = logging.getLogger(__name__);

"""Redis provider for Kubernetes deployments."""
class KubernetesRedisProvider(DatabaseProvider) {
    has target: (DeploymentTarget | None) = None,
        config: dict[str, Any] = {},
        app_name: str = '',
        connection_string: str = '';

    def init(
        self: KubernetesRedisProvider,
        target: (DeploymentTarget | None) = None,
        config: dict[str, Any] = {}
    ) -> None {
        self.target = target;
        self.config = config;
        self.app_name = config.get('app_name', 'jaseci');
    }

    """Load and generate Redis configuration from template."""
    def _load_redis_config(self: KubernetesRedisProvider) -> str {
        # Get configuration values from jac.toml
        scale_config = get_scale_config();
        db_config = scale_config.get_database_config();

        redis_max_memory = db_config.get('redis_max_memory', '200mb');
        redis_eviction_policy = db_config.get('redis_eviction_policy', 'allkeys-lru');
        redis_eviction_samples = db_config.get('redis_eviction_samples', 5);

        # Validate eviction policy
        valid_policies = [
            'allkeys-lru', 'volatile-lru', 'allkeys-lfu', 'volatile-lfu',
            'allkeys-random', 'volatile-random', 'volatile-ttl', 'noeviction'
        ];
        if redis_eviction_policy not in valid_policies {
            logger.warning(
                f"Invalid Redis eviction policy '{redis_eviction_policy}'. "
                f"Using default 'allkeys-lru'. Valid options: {', '.join(valid_policies)}"
            );
            redis_eviction_policy = 'allkeys-lru';
        }

        # Validate eviction samples (must be 1-10)
        try {
            samples = int(redis_eviction_samples);
            if samples < 1 or samples > 10 {
                logger.warning(
                    f"Redis eviction samples {samples} out of range [1-10]. Using default 5."
                );
                redis_eviction_samples = 5;
            } else {
                redis_eviction_samples = samples;
            }
        } except (ValueError, TypeError) {
            logger.warning(f"Invalid eviction samples value. Using default 5.");
            redis_eviction_samples = 5;
        }

        # Load template file with error handling
        try {
            template_path = Path(__file__).parent / 'redis.conf.template';
            if not template_path.exists() {
                raise FileNotFoundError(
                    f"Redis config template not found at: {template_path}\n"
                    f"Please ensure redis.conf.template exists in the same directory."
                );
            }

            template_content = template_path.read_text(encoding='utf-8');
            logger.debug(f"Loaded Redis config template from {template_path}");
        } except FileNotFoundError as e {
            logger.error(f"Redis config template missing: {e}");
            raise ;
        } except PermissionError as e {
            logger.error(f"Permission denied reading Redis config template: {e}");
            raise ValueError(f"Cannot read Redis config template: {e}");
        } except Exception as e {
            logger.error(f"Unexpected error reading Redis config template: {e}");
            raise ValueError(f"Failed to load Redis config template: {e}");
        }

        # Populate template with configuration values
        try {
            config_content = template_content.format(
                redis_max_memory=redis_max_memory,
                redis_eviction_policy=redis_eviction_policy,
                redis_eviction_samples=redis_eviction_samples
            );

            logger.info(
                f"Generated Redis config: maxmemory={redis_max_memory}, "
                f"policy={redis_eviction_policy}, samples={redis_eviction_samples}"
            );

            return config_content;
        } except KeyError as e {
            logger.error(f"Missing template variable in redis.conf.template: {e}");
            raise ValueError(f"Invalid Redis config template - missing variable: {e}");
        } except Exception as e {
            logger.error(f"Error populating Redis config template: {e}");
            raise ValueError(f"Failed to generate Redis config: {e}");
        }
    }

    """Calculate hash of Redis configuration for change detection."""
    def _calculate_config_hash(self: KubernetesRedisProvider, config_content: str) -> str {
        config_bytes = config_content.encode('utf-8');
        hash_obj = hashlib.md5(config_bytes);
        # Return first 8 chars for brevity (sufficient for change detection)
        return hash_obj.hexdigest()[:8];
    }

    def deploy(
        self: KubernetesRedisProvider, config: dict[str, Any] = {}
    ) -> dict[str, Any] {
        redis_name = f"{self.app_name}-redis";
        redis_port = 6379;
        redis_service_name = f"{redis_name}-service";
        redis_config_name = f"{redis_name}-config";

        # Load and generate Redis configuration
        redis_conf_content = self._load_redis_config();
        config_hash = self._calculate_config_hash(redis_conf_content);

        logger.debug(f"Redis config hash: {config_hash}");

        # Create ConfigMap for redis.conf
        redis_configmap = {
            'apiVersion': 'v1',
            'kind': 'ConfigMap',
            'metadata': {
                'name': redis_config_name,
                'labels': {
                    'app': redis_name,
                    'component': 'cache',
                    'managed-by': 'jac-scale'
                },
                'annotations': {
                    'config-hash': config_hash,
                    'description': 'Redis L2 cache configuration with LRU eviction'
                }
            },
            'data': {'redis.conf': redis_conf_content}
        };

        # Create Redis Deployment
        redis_deployment = {
            'apiVersion': 'apps/v1',
            'kind': 'Deployment',
            'metadata': {
                'name': redis_name,
                'labels': {
                    'app': redis_name,
                    'component': 'cache',
                    'managed-by': 'jac-scale'
                }
            },
            'spec': {
                'replicas': 1,
                'selector': {'matchLabels': {'app': redis_name}},
                'template': {
                    'metadata': {
                        'labels': {
                            'app': redis_name,
                            'component': 'cache'
                        },
                        'annotations': {
                            # This annotation triggers pod restart when config changes
                            'redis-config-hash': config_hash,
                            'description': 'Redis L2 cache with LRU eviction'
                        }
                    },
                    'spec': {
                        'containers': [
                            {
                                'name': 'redis',
                                'image': 'redis:7.2',
                                'ports': [{'containerPort': redis_port, 'name': 'redis'}],
                                'command': ['redis-server', '/etc/redis/redis.conf'],
                                'volumeMounts': [
                                    {
                                        'name': 'redis-config',
                                        'mountPath': '/etc/redis',
                                        'readOnly': True
                                    }
                                ],
                                'resources': {
                                    'requests': {'cpu': '100m', 'memory': '128Mi'},
                                    'limits': {'cpu': '500m', 'memory': '256Mi'}
                                },
                                'livenessProbe': {
                                    'tcpSocket': {'port': redis_port},
                                    'initialDelaySeconds': 10,
                                    'periodSeconds': 10,
                                    'timeoutSeconds': 5,
                                    'failureThreshold': 3
                                },
                                'readinessProbe': {
                                    'exec': {
                                        'command': ['redis-cli', 'ping']
                                    },
                                    'initialDelaySeconds': 5,
                                    'periodSeconds': 5,
                                    'timeoutSeconds': 3,
                                    'failureThreshold': 3
                                }
                            }
                        ],
                        'volumes': [
                            {
                                'name': 'redis-config',
                                'configMap': {'name': redis_config_name}
                            }
                        ]
                    }
                }
            }
        };

        redis_service = {
            'apiVersion': 'v1',
            'kind': 'Service',
            'metadata': {
                'name': redis_service_name,
                'labels': {
                    'app': redis_name,
                    'component': 'cache',
                    'managed-by': 'jac-scale'
                }
            },
            'spec': {
                'selector': {'app': redis_name},
                'ports': [
                    {
                        'protocol': 'TCP',
                        'port': redis_port,
                        'targetPort': redis_port,
                        'name': 'redis'
                    }
                ],
                'type': 'ClusterIP'
            }
        };

        self.connection_string = f"redis://{redis_service_name}:{redis_port}/0";

        logger.info(
            f"Prepared Redis deployment: {redis_name} "
            f"(connection: {self.connection_string}, config hash: {config_hash})"
        );

        return {
            'configmap': redis_configmap,
            'deployment': redis_deployment,
            'service': redis_service,
            'connection_string': self.connection_string,
            'service_name': redis_service_name,
            'config_hash': config_hash
        };
    }

    def get_connection_string(self: KubernetesRedisProvider) -> str {
        if not self.connection_string {
            # Generate default connection string
            service_name = f"{self.app_name}-redis-service";
            self.connection_string = f"redis://{service_name}:6379/0";
        }
        return self.connection_string;
    }

    def is_available(self: KubernetesRedisProvider) -> bool {
        # TODO: Implement actual check
        return True;
    }

    def cleanup(self: KubernetesRedisProvider) -> None {
    # Cleanup is handled by the deployment target
    }

    override def get_init_container(
        self: KubernetesRedisProvider, app_name: str, wait_image: str
    ) -> (dict[(str, Any)] | None) {
        return {
            'name': 'wait-for-redis',
            'image': wait_image,
            'command': [
                'sh',
                '-c',
                f"until nc -z {app_name}-redis-service 6379; do echo waiting for redis; sleep 3; done"
            ]
        };
    }
}
