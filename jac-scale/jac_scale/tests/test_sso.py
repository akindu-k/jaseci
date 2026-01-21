"""Test for SSO (Single Sign-On) implementation in jac-scale."""

import contextlib
import json
from dataclasses import dataclass
from types import TracebackType
from unittest.mock import AsyncMock, Mock, patch, MagicMock
from uuid import uuid4

import pytest
from fastapi import Request
from fastapi.responses import JSONResponse, RedirectResponse

from jac_scale.config_loader import reset_scale_config
from jac_scale.serve import JacAPIServer, Operations, Platforms
from jac_scale.user_manager import JacScaleUserManager
from jaclang.runtimelib.transport import TransportResponse


def mock_sso_config_with_credentials() -> dict:
    """Return mock SSO config with Google credentials configured."""
    return {
        "host": "http://localhost:8000/sso",
        "google": {
            "client_id": "test_client_id",
            "client_secret": "test_client_secret",
        },
    }


def mock_sso_config_without_credentials() -> dict:
    """Return mock SSO config without credentials."""
    return {
        "host": "http://localhost:8000/sso",
        "google": {
            "client_id": "",
            "client_secret": "",
        },
    }


def mock_sso_config_partial_credentials() -> dict:
    """Return mock SSO config with only client_id (no secret)."""
    return {
        "host": "http://localhost:8000/sso",
        "google": {
            "client_id": "test_id",
            "client_secret": "",
        },
    }


@dataclass
class MockUserInfo:
    """Mock user info from SSO provider."""

    email: str
    id: str = "mock_sso_id"
    first_name: str = "Test"
    last_name: str = "User"
    display_name: str = "Test User"
    picture: str = "https://example.com/picture.jpg"


class MockGoogleSSO:
    """Mock GoogleSSO for testing."""

    def __init__(
        self,
        client_id: str,
        client_secret: str,
        redirect_uri: str,
        allow_insecure_http: bool = False,
    ):
        self.client_id = client_id
        self.client_secret = client_secret
        self.redirect_uri = redirect_uri
        self.allow_insecure_http = allow_insecure_http
        # Set default callables that can be overridden
        self.get_login_redirect = self._default_get_login_redirect
        self.verify_and_process = self._default_verify_and_process

    async def _default_get_login_redirect(self) -> RedirectResponse:
        """Mock get_login_redirect method."""
        return RedirectResponse(url="https://accounts.google.com/oauth/authorize")

    async def _default_verify_and_process(self, _request: Request) -> MockUserInfo:
        """Mock verify_and_process method."""
        return MockUserInfo(email="test@example.com")

    def __enter__(self) -> "MockGoogleSSO":
        return self

    def __exit__(
        self,
        _exc_type: type[BaseException] | None,
        _exc_val: BaseException | None,
        _exc_tb: TracebackType | None,
    ) -> None:
        pass


class MockScaleConfig:
    """Mock JacScaleConfig for testing."""

    def __init__(self, sso_config: dict | None = None):
        self._sso_config = sso_config or mock_sso_config_with_credentials()

    def get_sso_config(self) -> dict:
        return self._sso_config
    
    def get_jwt_config(self) -> dict:
        return {
            "secret": "test_secret",
            "algorithm": "HS256",
            "exp_delta_days": 1,
        }


class TestJacScaleUserManagerSSO:
    """Test SSO functionality in JacScaleUserManager."""

    def setup_method(self) -> None:
        """Setup for each test method."""
        # Reset config singleton to ensure fresh config
        reset_scale_config()
        
        mock_config = MockScaleConfig(mock_sso_config_with_credentials())
        with patch("jac_scale.user_manager.get_scale_config", return_value=mock_config):
             with patch("jac_scale.user_manager.get_scale_config", return_value=mock_config):
                self.user_manager = JacScaleUserManager(base_path="")
                
        # Mock create_user and get_user which rely on storage
        self.user_manager.create_user = Mock()
        self.user_manager.get_user = Mock()


    @staticmethod
    def _get_response_body(result: JSONResponse | TransportResponse) -> str:
        """Extract body content from JSONResponse or TransportResponse."""
        if isinstance(result, JSONResponse):
            return result.body.decode("utf-8")
        elif isinstance(result, TransportResponse):
            # Convert TransportResponse to JSON string
            response_dict = {
                "ok": result.ok,
                "type": result.type,
                "data": result.data,
                "error": None,
            }
            if not result.ok and result.error:
                response_dict["error"] = {
                    "code": result.error.code,
                    "message": result.error.message,
                    "details": result.error.details,
                }
            if result.meta:
                meta_dict = {}
                if result.meta.request_id:
                    meta_dict["request_id"] = result.meta.request_id
                if result.meta.trace_id:
                    meta_dict["trace_id"] = result.meta.trace_id
                if result.meta.timestamp:
                    meta_dict["timestamp"] = result.meta.timestamp
                if result.meta.extra:
                    meta_dict["extra"] = result.meta.extra
                if meta_dict:
                    response_dict["meta"] = meta_dict
            return json.dumps(response_dict)
        else:
            raise TypeError(f"Unexpected response type: {type(result)}")

    def test_get_sso_with_google_platform(self) -> None:
        """Test get_sso returns GoogleSSO instance for Google platform."""
        # Patch GoogleSSO with side_effect to create MockGoogleSSO instances
        with patch("jac_scale.user_manager.GoogleSSO", side_effect=MockGoogleSSO) as mock_sso:
            sso = self.user_manager.get_sso(Platforms.GOOGLE.value, Operations.LOGIN.value)

            assert sso is not None
            # Verify attributes
            assert sso.client_id == "test_client_id"
            assert sso.client_secret == "test_client_secret"
            # Verify GoogleSSO was called with correct parameters
            mock_sso.assert_called_once()

    def test_get_sso_with_invalid_platform(self) -> None:
        """Test get_sso returns None for invalid platform."""
        sso = self.user_manager.get_sso("invalid_platform", Operations.LOGIN.value)
        assert sso is None

    def test_get_sso_with_unconfigured_platform(self) -> None:
        """Test get_sso returns None when platform credentials are not configured in jac.toml."""
        reset_scale_config()
        mock_config = MockScaleConfig(mock_sso_config_without_credentials())
        # Patch the correct location where get_scale_config is imported
        with patch("jac_scale.user_manager.get_scale_config", return_value=mock_config):
             # Re-init user manager to reload config
             user_manager = JacScaleUserManager(base_path="")
             sso = user_manager.get_sso(Platforms.GOOGLE.value, Operations.LOGIN.value)
             assert sso is None

    def test_get_sso_redirect_uri_format(self) -> None:
        """Test get_sso creates correct redirect URI based on jac.toml SSO host."""
        with patch("jac_scale.user_manager.GoogleSSO", side_effect=MockGoogleSSO) as mock_sso:
            sso = self.user_manager.get_sso(Platforms.GOOGLE.value, Operations.LOGIN.value)
            assert sso.redirect_uri == "http://localhost:8000/sso/google/login/callback"

    @pytest.mark.asyncio
    async def test_sso_initiate_success(self) -> None:
        """Test successful SSO initiation."""
        with patch.object(
            self.user_manager, "get_sso", return_value=MockGoogleSSO("id", "secret", "uri")
        ):
            result = await self.user_manager.sso_initiate(
                Platforms.GOOGLE.value, Operations.LOGIN.value
            )

            assert isinstance(result, RedirectResponse)
            assert "google.com" in result.headers.get("location", "")

    @pytest.mark.asyncio
    async def test_sso_initiate_with_invalid_platform(self) -> None:
        """Test SSO initiation with invalid platform."""
        result = await self.user_manager.sso_initiate(
            "invalid_platform", Operations.LOGIN.value
        )

        assert isinstance(result, (JSONResponse, TransportResponse))
        body = self._get_response_body(result)
        assert "Invalid platform" in body

    @pytest.mark.asyncio
    async def test_sso_initiate_with_unconfigured_platform(self) -> None:
        """Test SSO initiation with unconfigured platform."""
        # Clear supported platforms
        self.user_manager.SUPPORTED_PLATFORMS = {}

        result = await self.user_manager.sso_initiate(
            Platforms.GOOGLE.value, Operations.LOGIN.value
        )

        assert isinstance(result, (JSONResponse, TransportResponse))
        body = self._get_response_body(result)
        assert "not configured" in body

    @pytest.mark.asyncio
    async def test_sso_initiate_with_invalid_operation(self) -> None:
        """Test SSO initiation with invalid operation."""
        result = await self.user_manager.sso_initiate(
            Platforms.GOOGLE.value, "invalid_operation"
        )

        assert isinstance(result, (JSONResponse, TransportResponse))
        body = self._get_response_body(result)
        assert "Invalid operation" in body

    @pytest.mark.asyncio
    async def test_sso_initiate_when_get_sso_fails(self) -> None:
        """Test SSO initiation when get_sso returns None."""
        with patch.object(self.user_manager, "get_sso", return_value=None):
            result = await self.user_manager.sso_initiate(
                Platforms.GOOGLE.value, Operations.LOGIN.value
            )

            assert isinstance(result, (JSONResponse, TransportResponse))
            body = self._get_response_body(result)
            assert "Failed to initialize SSO" in body

    @pytest.mark.asyncio
    async def test_sso_callback_login_success(self) -> None:
        """Test successful SSO callback for login."""
        mock_request = Mock(spec=Request)

        self.user_manager.get_user.return_value = {
            "email": "test@example.com",
            "root_id": str(uuid4()),
        }

        mock_sso = MockGoogleSSO("id", "secret", "uri")
        mock_sso.verify_and_process = AsyncMock(
            return_value=MockUserInfo(email="test@example.com")
        )

        with (
            patch.object(self.user_manager, "get_sso", return_value=mock_sso),
            patch.object(
                self.user_manager, "create_jwt_token", return_value="mock_jwt_token"
            ),
        ):
            result = await self.user_manager.sso_callback(
                mock_request, Platforms.GOOGLE.value, Operations.LOGIN.value
            )

            assert isinstance(result, (JSONResponse, TransportResponse))
            body = self._get_response_body(result)

            assert "Login successful" in body
            assert "test@example.com" in body
            assert "mock_jwt_token" in body

    @pytest.mark.asyncio
    async def test_sso_callback_register_success(self) -> None:
        """Test successful SSO callback for registration."""
        mock_request = Mock(spec=Request)

        self.user_manager.get_user.return_value = None
        self.user_manager.create_user.return_value = {
            "email": "newuser@example.com",
            "root_id": str(uuid4()),
        }

        mock_sso = MockGoogleSSO("id", "secret", "uri")
        mock_sso.verify_and_process = AsyncMock(
            return_value=MockUserInfo(email="newuser@example.com")
        )

        with (
            patch.object(self.user_manager, "get_sso", return_value=mock_sso),
            patch.object(
                self.user_manager, "create_jwt_token", return_value="mock_jwt_token"
            ),
            patch(
                "jac_scale.user_manager.generate_random_password",
                return_value="random_pass",
            ),
        ):
            result = await self.user_manager.sso_callback(
                mock_request, Platforms.GOOGLE.value, Operations.REGISTER.value
            )

            assert isinstance(result, (JSONResponse, TransportResponse))
            self.user_manager.create_user.assert_called_once_with(
                "newuser@example.com", "random_pass"
            )

    @pytest.mark.asyncio
    async def test_sso_callback_login_user_not_found(self) -> None:
        """Test SSO callback for login when user doesn't exist."""
        mock_request = Mock(spec=Request)
        self.user_manager.get_user.return_value = None
        mock_sso = MockGoogleSSO("id", "secret", "uri")
        mock_sso.verify_and_process = AsyncMock(
            return_value=MockUserInfo(email="nonexistent@example.com")
        )
        with patch.object(self.user_manager, "get_sso", return_value=mock_sso):
            result = await self.user_manager.sso_callback(
                mock_request, Platforms.GOOGLE.value, Operations.LOGIN.value
            )
            assert isinstance(result, (JSONResponse, TransportResponse))
            body = self._get_response_body(result)
            assert "User not found" in body

    @pytest.mark.asyncio
    async def test_sso_callback_register_user_already_exists(self) -> None:
        """Test SSO callback for registration when user already exists."""
        mock_request = Mock(spec=Request)
        self.user_manager.get_user.return_value = {
            "email": "existing@example.com",
            "root_id": str(uuid4()),
        }
        mock_sso = MockGoogleSSO("id", "secret", "uri")
        mock_sso.verify_and_process = AsyncMock(
            return_value=MockUserInfo(email="existing@example.com")
        )
        with patch.object(self.user_manager, "get_sso", return_value=mock_sso):
            result = await self.user_manager.sso_callback(
                mock_request, Platforms.GOOGLE.value, Operations.REGISTER.value
            )
            assert isinstance(result, (JSONResponse, TransportResponse))
            body = self._get_response_body(result)
            assert "User already exists" in body

    @pytest.mark.asyncio
    async def test_sso_callback_with_invalid_platform(self) -> None:
        """Test SSO callback with invalid platform."""
        mock_request = Mock(spec=Request)

        result = await self.user_manager.sso_callback(
            mock_request, "invalid_platform", Operations.LOGIN.value
        )
        assert isinstance(result, (JSONResponse, TransportResponse))
        body = self._get_response_body(result)
        assert "Invalid platform" in body

    @pytest.mark.asyncio
    async def test_sso_callback_with_unconfigured_platform(self) -> None:
        """Test SSO callback with unconfigured platform."""
        mock_request = Mock(spec=Request)
        self.user_manager.SUPPORTED_PLATFORMS = {}
        result = await self.user_manager.sso_callback(
            mock_request, Platforms.GOOGLE.value, Operations.LOGIN.value
        )
        assert isinstance(result, (JSONResponse, TransportResponse))
        body = self._get_response_body(result)
        assert "not configured" in body

    @pytest.mark.asyncio
    async def test_sso_callback_with_invalid_operation(self) -> None:
        """Test SSO callback with invalid operation."""
        mock_request = Mock(spec=Request)
        result = await self.user_manager.sso_callback(
            mock_request, Platforms.GOOGLE.value, "invalid_operation"
        )
        assert isinstance(result, (JSONResponse, TransportResponse))
        body = self._get_response_body(result)
        assert "Invalid operation" in body

    @pytest.mark.asyncio
    async def test_sso_callback_when_get_sso_fails(self) -> None:
        """Test SSO callback when get_sso returns None."""
        mock_request = Mock(spec=Request)
        with patch.object(self.user_manager, "get_sso", return_value=None):
            result = await self.user_manager.sso_callback(
                mock_request, Platforms.GOOGLE.value, Operations.LOGIN.value
            )
            assert isinstance(result, (JSONResponse, TransportResponse))
            body = self._get_response_body(result)
            assert "Failed to initialize SSO" in body

    @pytest.mark.asyncio
    async def test_sso_callback_when_email_not_provided(self) -> None:
        """Test SSO callback when email is not provided by SSO provider."""
        mock_request = Mock(spec=Request)
        mock_sso = MockGoogleSSO("id", "secret", "uri")
        mock_user_info = MockUserInfo(email="")
        mock_user_info.email = None  # type: ignore
        mock_sso.verify_and_process = AsyncMock(return_value=mock_user_info)
        with patch.object(self.user_manager, "get_sso", return_value=mock_sso):
            result = await self.user_manager.sso_callback(
                mock_request, Platforms.GOOGLE.value, Operations.LOGIN.value
            )
            assert isinstance(result, (JSONResponse, TransportResponse))
            body = self._get_response_body(result)
            assert "Email not provided" in body

    @pytest.mark.asyncio
    async def test_sso_callback_authentication_failure(self) -> None:
        """Test SSO callback when authentication fails."""
        mock_request = Mock(spec=Request)
        mock_sso = MockGoogleSSO("id", "secret", "uri")
        mock_sso.verify_and_process = AsyncMock(
            side_effect=Exception("Authentication failed")
        )
        with patch.object(self.user_manager, "get_sso", return_value=mock_sso):
            result = await self.user_manager.sso_callback(
                mock_request, Platforms.GOOGLE.value, Operations.LOGIN.value
            )
            assert isinstance(result, (JSONResponse, TransportResponse))
            body = self._get_response_body(result)
            assert "Authentication failed" in body

    def test_supported_platforms_initialization_with_jac_toml_credentials(self) -> None:
        """Test SUPPORTED_PLATFORMS initialization when credentials are in jac.toml."""
        reset_scale_config()
        mock_config = MockScaleConfig(
            {
                "host": "http://localhost:8000/sso",
                "google": {
                    "client_id": "toml_test_id",
                    "client_secret": "toml_test_secret",
                },
            }
        )
        # Patch both places where config is loaded
        with patch("jac_scale.user_manager.get_scale_config", return_value=mock_config):
             with patch("jac_scale.user_manager.get_scale_config", return_value=mock_config):
                user_manager = JacScaleUserManager(base_path="")
                assert "google" in user_manager.SUPPORTED_PLATFORMS
                assert user_manager.SUPPORTED_PLATFORMS["google"]["client_id"] == "toml_test_id"

    def test_supported_platforms_initialization_without_jac_toml_credentials(
        self,
    ) -> None:
        """Test SUPPORTED_PLATFORMS initialization when credentials are missing from jac.toml."""
        reset_scale_config()
        mock_config = MockScaleConfig(mock_sso_config_without_credentials())
        with patch("jac_scale.user_manager.get_scale_config", return_value=mock_config):
             with patch("jac_scale.user_manager.get_scale_config", return_value=mock_config):
                user_manager = JacScaleUserManager(base_path="")
                assert "google" not in user_manager.SUPPORTED_PLATFORMS


class TestJacAPIServerEndpoints:
    """Test SSO endpoints registration in JacAPIServer."""
    
    def setup_method(self) -> None:
        self.mock_server_impl = Mock()
        self.mock_user_manager = Mock()
        self.mock_config = MockScaleConfig(mock_sso_config_with_credentials())
        
        with patch("jac_scale.serve.get_scale_config", return_value=self.mock_config):
             # We need to mock JacAPIServer user manager creation or it will create a real one.
             # The real one is fine if we mock its methods, or we can mock Jac.get_user_manager
             with patch("jaclang.pycore.runtime.JacRuntimeInterface.get_user_manager", return_value=self.mock_user_manager):
                self.server = JacAPIServer(module_name="test_module", port=8000)
        
        self.server.server = self.mock_server_impl
        # self.server.user_manager is already mocked via hook

    def test_register_sso_endpoints(self) -> None:
        """Test SSO endpoints registration."""
        self.mock_server_impl.reset_mock()
        self.server.register_sso_endpoints()
        assert self.mock_server_impl.add_endpoint.call_count == 2
        calls = self.mock_server_impl.add_endpoint.call_args_list
        first_endpoint = calls[0][0][0]
        assert "/sso/{platform}/{operation}" in first_endpoint.path
        assert first_endpoint.method.name == "GET"
        
        # Verify callback is linked to user_manager
        # Note: In register_sso_endpoints implementation, it uses self.user_manager.sso_initiate
        assert first_endpoint.callback == self.mock_user_manager.sso_initiate

