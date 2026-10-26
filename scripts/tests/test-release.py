import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith('ANYREC_')}

    def run_command(self, *args, cwd=None):
        return subprocess.run(args, cwd=cwd, env=self.env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def git(self, *args):
        result = self.run_command('git', '-C', str(self.root), *args)
        self.assertEqual(result.returncode, 0, result.stderr)

    def tag_fixture(self):
        (self.root / 'scripts').mkdir()
        source = self.root / 'Sources/anyrec'
        source.mkdir(parents=True)
        (source / 'AnyRec.swift').write_text('version: "1.2.3",\n')
        shutil.copy(ROOT / 'scripts/release-tag.sh', self.root / 'scripts')
        self.git('init', '-q')
        self.git('config', 'user.name', 'Release Test')
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        self.git('tag', 'v1.2.3')

    def validate_tag(self, tag):
        return self.run_command('bash', str(self.root / 'scripts/release-tag.sh'), tag)

    def test_matching_tag(self):
        self.tag_fixture()
        self.assertEqual(self.validate_tag('v1.2.3').returncode, 0)

    def test_version_mismatch_and_invalid_input(self):
        self.tag_fixture()
        for tag in ['v1.2.4', 'v1.2.3-beta', 'main', 'v01.2.3', 'v1.2.3; exit 0']:
            with self.subTest(tag=tag):
                self.assertNotEqual(self.validate_tag(tag).returncode, 0)

    def test_tag_must_point_at_checkout(self):
        self.tag_fixture()
        self.git('commit', '--allow-empty', '-qm', 'another commit')
        self.assertNotEqual(self.validate_tag('v1.2.3').returncode, 0)

    def signing_fixture(self):
        self.env.update(PATH=f'{self.root}:{os.environ["PATH"]}',
                        ANYREC_SIGN_IDENTITY='Developer ID Application: Test',
                        ANYREC_REQUIRE_NOTARIZATION='1',
                        TEST_CALL_LOG=str(self.root / 'calls'))
        self.tool('security', 'echo "Developer ID Application: Test"\n')
        self.tool('xcrun', '''
echo "$*" >>"$TEST_CALL_LOG"
case "$1 $2" in
  'notarytool history') exit "${TEST_HISTORY_EXIT:-0}" ;;
  'notarytool submit')
    printf '{"status":"%s"}\\n' "${TEST_NOTARY_STATUS:-Accepted}"
    exit "${TEST_SUBMIT_EXIT:-0}" ;;
  'stapler staple') exit "${TEST_STAPLE_EXIT:-0}" ;;
esac
''')

    def tool(self, name, contents):
        path = self.root / name
        path.write_text('#!/bin/bash\n' + contents)
        path.chmod(0o700)

    def notarize(self):
        return self.run_command('bash', '-eu', '-c',
                                'source "$1"; notarize archive.zip AnyRec.app',
                                'test', str(ROOT / 'scripts/signing.sh'))

    def test_strict_signing_rejects_missing_identity_and_adhoc(self):
        self.signing_fixture()
        self.tool('security', 'exit 0\n')
        self.assertNotEqual(self.notarize().returncode, 0)
        self.env['ANYREC_SIGN_IDENTITY'] = '-'
        self.assertNotEqual(self.notarize().returncode, 0)

    def test_notarization_requires_accepted_status(self):
        self.signing_fixture()
        self.env['TEST_NOTARY_STATUS'] = 'Invalid'
        self.assertNotEqual(self.notarize().returncode, 0)
        self.assertNotIn('stapler', (self.root / 'calls').read_text())

    def test_notary_command_and_stapling_failures_propagate(self):
        self.signing_fixture()
        for key in ['TEST_HISTORY_EXIT', 'TEST_SUBMIT_EXIT', 'TEST_STAPLE_EXIT']:
            with self.subTest(key=key):
                self.env[key] = '1'
                self.assertNotEqual(self.notarize().returncode, 0)
                del self.env[key]

    def test_accepted_submission_staples_and_validates(self):
        self.signing_fixture()
        self.assertEqual(self.notarize().returncode, 0)
        log = (self.root / 'calls').read_text()
        self.assertIn('stapler staple AnyRec.app', log)
        self.assertIn('stapler validate AnyRec.app', log)

    def test_release_preserves_app_bundle_failure_output(self):
        scripts = self.root / 'scripts'
        scripts.mkdir()
        source = self.root / 'Sources/anyrec'
        source.mkdir(parents=True)
        (source / 'AnyRec.swift').write_text('version: "1.2.3",\n')
        shutil.copy(ROOT / 'scripts/release.sh', scripts)
        (scripts / 'signing.sh').write_text(
            'SIGN_IDENTITY=test\nnotarize_archive() { return 0; }\n')
        (scripts / 'embed-whisper.sh').write_text('embed_whisper() { return 0; }\n')
        bundle = scripts / 'bundle-app.sh'
        bundle.write_text('#!/bin/bash\necho "app linker failure"\nexit 1\n')
        bundle.chmod(0o700)
        binary = self.root / 'anyrec'
        binary.write_text('fixture')
        self.env.update(PATH=f'{self.root}:{os.environ["PATH"]}',
                        TEST_BINARY_DIR=str(self.root), ANYREC_REQUIRE_NOTARIZATION='1')
        self.tool('swift', 'echo "$TEST_BINARY_DIR"\n')
        self.tool('codesign', 'exit 0\n')
        self.tool('ditto', 'touch "${@: -1}"\n')
        self.tool('tar', 'exit 0\n')
        result = self.run_command('bash', str(scripts / 'release.sh'), '1.2.3')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('app linker failure', result.stdout + result.stderr)

    def test_missing_ci_secrets_stop_before_keychain_creation(self):
        result = self.run_command('bash', str(ROOT / 'scripts/ci-signing.sh'), 'check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing GitHub secret:', result.stderr)

    def test_ci_keychain_setup_and_cleanup_do_not_print_credentials(self):
        self.signing_fixture()
        self.env.update(RUNNER_TEMP=str(self.root), GITHUB_ENV=str(self.root / 'env'),
                        ANYREC_CERTIFICATE_BASE64='dGVz\ndA==',
                        ANYREC_CERTIFICATE_PASSWORD='synthetic-password',
                        ANYREC_NOTARY_KEY='-----BEGIN PRIVATE KEY-----\nsynthetic-private-key',
                        ANYREC_NOTARY_KEY_ID='X123456789',
                        ANYREC_NOTARY_ISSUER_ID='00000000-0000-0000-0000-000000000000')
        script = str(ROOT / 'scripts/ci-signing.sh')
        prepared = self.run_command('bash', script, 'prepare')
        self.assertEqual(prepared.returncode, 0, prepared.stderr)
        for secret in ['synthetic-password', 'synthetic-private-key', 'X123456789']:
            self.assertNotIn(secret, prepared.stdout + prepared.stderr)
        self.assertIn('ANYREC_NOTARY_PROFILE=anyrec-ci', (self.root / 'env').read_text())
        self.assertFalse((self.root / 'anyrec-signing/certificate.p12').exists())
        self.assertFalse((self.root / 'anyrec-signing/notary.p8').exists())
        self.assertEqual(self.run_command('bash', script, 'cleanup').returncode, 0)
        self.assertFalse((self.root / 'anyrec-signing').exists())

    def test_invalid_issuer_is_rejected_without_disclosing_its_value(self):
        self.env.update(ANYREC_CERTIFICATE_BASE64='dGVzdA==',
                        ANYREC_CERTIFICATE_PASSWORD='test', ANYREC_NOTARY_KEY='test',
                        ANYREC_NOTARY_KEY_ID='X123456789', ANYREC_NOTARY_ISSUER_ID='wrong-issuer')
        result = self.run_command('bash', str(ROOT / 'scripts/ci-signing.sh'), 'check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ANYREC_NOTARY_ISSUER_ID has an invalid format', result.stderr)
        self.assertNotIn('wrong-issuer', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
