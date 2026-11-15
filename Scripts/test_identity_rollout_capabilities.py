#!/usr/bin/env python3
"""Hermetic capability tests: fixture bytes are not runtime migration proof."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import stable_rollout as rollout

ROOT = Path(__file__).resolve().parent.parent
POLICY = ROOT / 'Scripts/apple_identity_policy.json'


class CapabilityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.policy = rollout.load_policy(POLICY)
        self.p = self.native('tip', 'preparer', '43.24.43', 'tip-1e1d9fe4bbc6')

    def declaration(self, channel, role, predecessors=(), adoption=None):
        d = dict(schemaVersion=2 if channel == 'stable' and (predecessors or adoption) else 1,
                 channel=channel, currentRole=role, eligibilityProfile='fixture',
                 expectedMigrationPhase=rollout.ROLE_MIGRATION_PHASE[role],
                 expectedSigningIdentity=rollout.ROLE_IDENTITY[role], predecessors=[])
        for manifest in predecessors:
            m = json.loads(manifest.read_text())
            entry = dict(role=m['currentRole'], tag=m['sourceTag'], rolloutManifestSha256=rollout.sha256_file(manifest))
            if channel == 'stable':
                entry['sourceChannel'] = m['channel']
            d['predecessors'].append(entry)
        if d['schemaVersion'] == 2:
            d['runtimeMigrationProof'] = rollout.RUNTIME_PROOF_ACCEPTED_RISK
        if adoption:
            d['adoptedArtifact'] = adoption
        return d

    def write(self, path, value):
        path.write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')
        return path

    def native(self, channel, role, build, tag, predecessors=()):
        directory = self.root / tag
        directory.mkdir()
        declaration = self.write(directory / 'declaration.json', self.declaration(channel, role, predecessors))
        identity = self.policy['identities'][rollout.ROLE_IDENTITY[role]]
        version = directory / 'version.env'
        marketing = tag[1:] if channel == 'stable' else '1.9.1'
        version.write_text(f'APP_NAME=RepoPrompt\nMARKETING_VERSION={marketing}\nBUILD_NUMBER={build}\nBUNDLE_ID={identity["bundleIdentifier"]}\nSIGNING_TEAM_ID={identity["teamIdentifier"]}\n')
        artifact = self.write(directory / 'artifact.json', {'fixture': True})
        enclosure = directory / rollout.expected_enclosure_name('RepoPrompt', marketing, build, role)
        enclosure.write_bytes(b'fixture archive')
        args = argparse.Namespace(policy=str(POLICY), declaration=str(declaration), version_env=str(version),
                                  allowed_roles=None, release_tag=tag, release_commit='a'*40,
                                  migration_phase=rollout.ROLE_MIGRATION_PHASE[role], enclosure=str(enclosure),
                                  enclosure_basename=None, enclosure_signature='fixture-signature',
                                  app_artifact_manifest=str(artifact), predecessor_manifest=list(map(str, predecessors)))
        manifest, appcast = rollout.build_manifest(args)
        path = self.write(directory / 'manifest.json', manifest)
        (directory / 'appcast.xml').write_text(appcast)
        return path

    def adoption_args(self):
        authority = dict(type=rollout.ADOPTION_TYPE, tag='tip-1e1d9fe4bbc6', buildNumber='43.24.43',
                         rolloutManifestSha256=rollout.sha256_file(self.p))
        declaration = self.write(self.root / 'adoption-declaration.json', self.declaration('stable', 'preparer', adoption=authority))
        return argparse.Namespace(policy=str(POLICY), declaration=str(declaration), tip_manifest=str(self.p), tip_appcast=str(self.p.parent/'appcast.xml'))

    def adoption(self):
        m = rollout.build_adoption(self.adoption_args())
        directory = self.root/'adoption'
        directory.mkdir(exist_ok=True)
        path = self.write(directory/'manifest.json', m)
        (directory/'appcast.xml').write_text(rollout.render_appcast(m))
        return path

    def handoff(self, stable, tip):
        rollout.run_validate_stable_tip_floor(argparse.Namespace(policy=str(POLICY), stable_manifest=str(stable),
            stable_appcast=str(stable.parent/'appcast.xml'), tip_manifest=str(tip), tip_appcast=str(tip.parent/'appcast.xml')))

    def progression(self, candidate, live):
        rollout.run_validate_live_stable_progression(argparse.Namespace(policy=str(POLICY), candidate_manifest=str(candidate),
            candidate_appcast=str(candidate.parent/'appcast.xml'), live_manifest=str(live), live_appcast=str(live.parent/'appcast.xml')))

    def test_unchanged_adoption_retains_exact_origin_and_deterministic_bytes(self):
        args = self.adoption_args()
        manifest = rollout.build_adoption(args)
        self.assertEqual(manifest, rollout.build_adoption(args))
        p = json.loads(self.p.read_text())
        item = manifest['appcastItems'][0]
        self.assertEqual(item, rollout.bind_live_item(p, rollout.sha256_file(self.p)))
        for key in ('releaseCommit', 'marketingVersion', 'buildNumber', 'appArtifactManifest'):
            self.assertEqual(manifest[key], p[key])
        adopted = self.adoption()
        rollout.validate_manifest_pair(self.policy, adopted, adopted.parent/'appcast.xml', 'fixture', 'stable')
        self.handoff(adopted, self.p)

    def test_adoption_pins_and_risk_acknowledgement_fail_closed(self):
        for key, value in [('tag','tip-000000000000'), ('buildNumber','43.24.44'), ('rolloutManifestSha256','0'*64)]:
            with self.subTest(key=key):
                args = self.adoption_args()
                d = json.loads(Path(args.declaration).read_text())
                d['adoptedArtifact'][key] = value
                self.write(Path(args.declaration), d)
                with self.assertRaises(rollout.RolloutError): rollout.build_adoption(args)
        args = self.adoption_args()
        d = json.loads(Path(args.declaration).read_text())
        for proof in ('passed', None, ''):
            d['runtimeMigrationProof'] = proof
            self.write(Path(args.declaration), d)
            with self.assertRaises(rollout.RolloutError): rollout.load_declaration(Path(args.declaration))

    def test_stable_ladder_legacy_adoption_transition_successor(self):
        legacy = self.native('stable','legacy','43','v1.9.1')
        adopted = self.adoption()
        self.progression(adopted, legacy)
        t = self.native('stable','transition','44','v1.9.2',(self.p,))
        self.progression(t, adopted)
        s = self.native('stable','successor','45','v1.9.3',(t,self.p))
        self.progression(s,t)
        self.progression(s,s)
        m = json.loads(s.read_text())
        self.assertEqual(m['appcastItems'][-1], json.loads(adopted.read_text())['appcastItems'][0])
        with self.assertRaises(rollout.RolloutError): self.progression(s,adopted)
        with self.assertRaises(rollout.RolloutError): self.progression(adopted,t)

    def test_handoff_admits_shared_bridge_but_requires_tip_to_lead(self):
        adopted = self.adoption()
        tip_t = self.native('tip','transition','43.24.44','tip-222222222222',(self.p,))
        stable_t = self.native('stable','transition','44','v1.9.2',(self.p,))
        self.handoff(adopted,tip_t)
        self.handoff(stable_t,tip_t)
        with self.assertRaisesRegex(rollout.RolloutError,'rehearse'): self.handoff(stable_t,self.p)
        legacy = self.native('stable','legacy','44','v1.9.4')
        with self.assertRaisesRegex(rollout.RolloutError,'Stable=44'): self.handoff(legacy,tip_t)
        bad = json.loads(stable_t.read_text())
        bad['appcastItems'][-1]['rolloutManifestSha256'] = '0'*64
        self.write(stable_t,bad)
        (stable_t.parent/'appcast.xml').write_text(rollout.render_appcast(bad))
        with self.assertRaisesRegex(rollout.RolloutError,'same authenticated preparer'): self.handoff(stable_t,tip_t)

    def test_retained_history_tampering_and_same_tag_rewrite_rejected(self):
        adopted = self.adoption()
        t = self.native('stable','transition','44','v1.9.2',(self.p,))
        bad = json.loads(t.read_text())
        bad['appcastItems'][-1]['edSignature'] = 'tampered'
        self.write(t,bad); (t.parent/'appcast.xml').write_text(rollout.render_appcast(bad))
        with self.assertRaisesRegex(rollout.RolloutError,'retained history'): self.progression(t,adopted)
        duplicate = self.root/'duplicate'; duplicate.mkdir()
        self.write(duplicate/'manifest.json',bad)
        (duplicate/'appcast.xml').write_text(rollout.render_appcast(bad))
        bad['releaseCommit'] = 'b'*40
        self.write(t,bad)
        with self.assertRaisesRegex(rollout.RolloutError,'different bytes'): self.progression(t,duplicate/'manifest.json')

    def test_operation_matrix_and_declarations_remain_dormant(self):
        args = self.adoption_args()
        transition = self.native('stable','transition','44','v1.9.2',(self.p,))
        for declaration, allowed in [(ROOT/'release-rollout.json',{'build','promote'}),
                                     (Path(args.declaration),{'adopt'}),
                                     (transition.parent/'declaration.json',{'build','promote'})]:
            for operation in ('build','promote','adopt'):
                a = argparse.Namespace(policy=str(POLICY),declaration=str(declaration),operation=operation)
                if operation in allowed: rollout.run_workflow_guard(a)
                else:
                    with self.assertRaises(rollout.RolloutError): rollout.run_workflow_guard(a)
        self.assertEqual(rollout.load_declaration(ROOT/'release-rollout.json')['currentRole'],'legacy')
        self.assertEqual(rollout.load_declaration(ROOT/'tip-rollout.json')['currentRole'],'preparer')

    def test_build_number_above_dotted_stable_and_bad_ranges(self):
        stable = self.adoption()
        for sequence, okay in ((2443,False),(2444,True),(10000,False),(0,False)):
            args=argparse.Namespace(stable_appcast=str(stable.parent/'appcast.xml'),sequence=sequence)
            if okay: rollout.run_tip_build_number(args)
            else:
                with self.assertRaises(rollout.RolloutError): rollout.run_tip_build_number(args)

    def test_adopted_origin_cannot_be_a_transition_or_an_unbound_item(self):
        m=rollout.build_adoption(self.adoption_args())
        for key,value in [('role','transition'),('rolloutManifestSha256',None),('url','https://example.com/archive.zip')]:
            item=copy.deepcopy(m['appcastItems'][0]); item[key]=value
            with self.assertRaises(rollout.RolloutError): rollout.validate_item_shape(item,1,self.policy,'RepoPrompt','stable')


class WorkflowBoundaryTests(unittest.TestCase):
    def test_adoption_has_no_signing_or_notary_secrets(self):
        workflow=(ROOT/'.github/workflows/release-adopt-tip-preparer.yml').read_text()
        for forbidden in ('SPARKLE_PRIVATE_KEY','DEVELOPER_ID','NOTARYTOOL','release.sh publish-staged'):
            self.assertNotIn(forbidden,workflow)
        self.assertIn('environment: release',workflow)
        self.assertIn('env -i',workflow)
        for name in ('main-tip.yml','release-promote.yml','release-adopt-tip-preparer.yml'):
            self.assertIn('group: rollout-publication',(ROOT/'.github/workflows'/name).read_text())

    def test_adoption_rejected_before_download_when_not_activated(self):
        result=subprocess.run(['bash',str(ROOT/'Scripts/adopt_tip_preparer.sh'),'verify'],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('not activated',result.stderr)

    def test_adoption_reconciliation_is_paginated_and_never_overwrites(self):
        for scenario, okay, creates in [('absent',True,True),('matching',True,False),('different',False,False),('duplicate',False,False),('transport',False,False)]:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as directory:
                d=Path(directory); feed=d/'feed'; feed.mkdir(); (feed/'appcast.xml').write_text('reviewed')
                work=d/'work'; work.mkdir()
                stub=d/'gh'
                stub.write_text('''#!/usr/bin/env python3
import json,os,pathlib,shutil,sys
args=sys.argv[1:]; scenario=os.environ['SCENARIO']; root=pathlib.Path(os.environ['FIXTURE'])
with (root/'calls').open('a') as f: f.write(json.dumps(args)+'\\n')
if args[0]=='api':
    assert '--paginate' in args and '--slurp' in args
    if scenario=='transport': sys.exit(7)
    r={'tag_name':'stable-adopt-tip-111111111111','prerelease':False}
    print(json.dumps([[],[] if scenario=='absent' else [r,r] if scenario=='duplicate' else [r]]))
elif args[:2]==['release','download']:
    output=pathlib.Path(args[args.index('--dir')+1]); (output/'appcast.xml').write_text('tampered' if scenario=='different' else 'reviewed')
elif args[:2]==['release','create']: pass
else: sys.exit(99)
'''); stub.chmod(0o755)
                command=['bash','-c','set -euo pipefail; source "$1"; update_gh(){ gh "$@"; }; prepare_adoption_release "$2" owner/repo stable-adopt-tip-111111111111 fixture "$3"','test',str(ROOT/'Scripts/release_observation.sh'),str(feed),str(work)]
                result=subprocess.run(command,env={**os.environ,'PATH':str(d)+':'+os.environ['PATH'],'SCENARIO':scenario,'FIXTURE':str(d)},capture_output=True,text=True)
                self.assertEqual(result.returncode==0,okay,result.stdout+result.stderr)
                calls=[json.loads(line) for line in (d/'calls').read_text().splitlines()]
                self.assertEqual(any(call[:2]==['release','create'] for call in calls),creates)
                self.assertFalse(any(call[:2] in (['release','upload'],['release','delete']) for call in calls))

    def test_stable_transition_package_build_and_promotion_branches(self):
        fixture=CapabilityTests(); fixture.setUp(); self.addCleanup(fixture.doCleanups)
        transition=fixture.native('stable','transition','44','v1.9.2',(fixture.p,))
        d=fixture.root/'stub-scripts'; d.mkdir()
        package=d/'build_identity_transition_pkg.sh'
        package.write_text('#!/bin/bash\n[[ "$REPOPROMPT_ENABLE_IDENTITY_TRANSITION_PKG" == 1 ]] || exit 91\nprintf "%s\\n" "$*" >> "$RECEIPT"\n'); package.chmod(0o755)
        receipt=fixture.root/'receipt'
        build_script='''set -euo pipefail
source "$1/Scripts/release.sh"
CONTROL_PLANE_SCRIPTS_DIR="$2"
APP_BUNDLE=fixture.app
EXPECTED_INSTALLER_IDENTITY='Samuel Installer fixture'
submit_notarization(){ printf 'notarize %s\\n' "$1" >> "$RECEIPT"; }
build_notarized_stable_transition_package fixture.pkg
'''
        env={**os.environ,'RECEIPT':str(receipt)}
        result=subprocess.run(['bash','-c',build_script,'test',str(ROOT),str(d)],env=env,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        calls=receipt.read_text().splitlines()
        self.assertEqual([line.split()[0] for line in calls],['build','notarize','staple','validate'])
        self.assertIn('--installer-identity Samuel Installer fixture',calls[0])
        receipt.write_text('')
        promotion_script='''set -euo pipefail
source "$1/Scripts/promote_release.sh"
ROLLOUT_DECLARATION="$3"
resolve_release_artifact_role
[[ "$PRIMARY_ARTIFACT_NAME" == *.pkg ]]
if release_role_ships_dmg; then exit 92; fi
CONTROL_PLANE_SCRIPTS_DIR="$2"
PRIMARY_ARTIFACT=fixture.pkg
EXTRACT_DIR=fixture-extracted
# A package must never enter the ZIP extractor.
ditto(){ exit 93; }
extract_reviewed_update
'''
        result=subprocess.run(['bash','-c',promotion_script,'test',str(ROOT),str(d),str(transition.parent/'declaration.json')],env=env,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(receipt.read_text().strip(),'validate fixture.pkg --expanded-payload-dir fixture-extracted')

    def test_stable_context_role_matrix(self):
        fixture = CapabilityTests(); fixture.setUp(); self.addCleanup(fixture.doCleanups)
        transition = fixture.native('stable','transition','44','v1.9.2',(fixture.p,))
        successor = fixture.native('stable','successor','45','v1.9.3',(transition,fixture.p))
        for manifest in (transition, successor):
            declaration = manifest.parent/'declaration.json'
            for corrupt in ('', 'installer', 'anchor', 'kind'):
                with self.subTest(role=manifest.parent.name, corrupt=corrupt):
                    script = '''set -euo pipefail
source "$1/Scripts/load_release_metadata.sh"
eval "$(python3 "$1/Scripts/stable_rollout.py" packaging-context --policy "$1/Scripts/apple_identity_policy.json" --declaration "$2" --version-env "$3")"
case "$4" in
installer) EXPECTED_INSTALLER_TEAM_ID=wrong; EXPECTED_INSTALLER_IDENTITY=wrong ;;
anchor) EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID=unexpected ;;
kind) if [[ "$ROLLOUT_INSTALLATION_TYPE" == package ]]; then ROLLOUT_INSTALLATION_TYPE=application; else ROLLOUT_INSTALLATION_TYPE=package; fi ;;
esac
validate_stable_release_context "$BUNDLE_ID" "$SIGNING_TEAM_ID" "$REPOPROMPT_IDENTITY_MIGRATION_PHASE" "$EXPECTED_SIGN_IDENTITY"
'''
                    result=subprocess.run(['bash','-c',script,'test',str(ROOT),str(declaration),str(manifest.parent/'version.env'),corrupt],capture_output=True,text=True)
                    self.assertEqual(result.returncode==0,not corrupt,result.stderr)

    def test_observation_without_digest_uses_authenticated_asset_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            d=Path(directory); metadata=d/'metadata.json'; output=d/'output'
            metadata.write_text(json.dumps(dict(tag_name='v1',assets=[dict(id=42,name='appcast.xml',state='uploaded',size=7,digest=None,
                browser_download_url='https://github.com/owner/repo/releases/download/v1/appcast.xml')])))
            gh=d/'gh'; gh.write_text('#!/bin/bash\n[[ "$GH_TOKEN" == fixture ]] || exit 91\n[[ "$*" == "api repos/owner/repo/releases/assets/42 -H Accept: application/octet-stream" ]] || exit 92\nprintf fixture\n'); gh.chmod(0o755)
            curl=d/'curl'; curl.write_text('#!/bin/bash\nexit 93\n'); curl.chmod(0o755)
            env={**os.environ,'PATH':str(d)+':'+os.environ['PATH'],'OBSERVATION_GH_TOKEN':'fixture'}
            command=['bash','-c','source "$1"; fetch_observed_asset "$2" owner/repo appcast.xml "$3"','test',str(ROOT/'Scripts/release_observation.sh'),str(metadata),str(output)]
            result=subprocess.run(command,env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(output.read_bytes(),b'fixture')

    def test_observation_requires_matching_api_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            d=Path(directory); metadata=d/'metadata.json'; payload=d/'payload'
            payload.write_bytes(b'fixture')
            asset=dict(name='appcast.xml',state='uploaded',size=7,digest='sha256:'+hashlib.sha256(b'fixture').hexdigest(),
                       browser_download_url='https://github.com/owner/repo/releases/download/v1/appcast.xml')
            metadata.write_text(json.dumps(dict(tag_name='v1',assets=[asset])))
            stub=d/'curl'; stub.write_text('#!/bin/bash\nexit 0\n'); stub.chmod(0o755)
            command=['bash','-c','source "$1"; fetch_observed_asset "$2" owner/repo appcast.xml "$3"','test',str(ROOT/'Scripts/release_observation.sh'),str(metadata),str(payload)]
            env={**os.environ,'PATH':str(d)+':'+os.environ['PATH']}
            self.assertEqual(subprocess.run(command,env=env,capture_output=True).returncode,0)
            asset['digest']='sha256:'+'0'*64
            metadata.write_text(json.dumps(dict(tag_name='v1',assets=[asset])))
            self.assertNotEqual(subprocess.run(command,env=env,capture_output=True).returncode,0)


if __name__ == '__main__': unittest.main()
