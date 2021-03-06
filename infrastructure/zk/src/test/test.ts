import { Command } from 'commander';
import * as utils from '../utils';
import * as contract from '../contract';

import * as integration from './integration';
export { integration };

export async function db(reset: boolean) {
    const databaseUrl = process.env.DATABASE_URL as string;
    process.env.DATABASE_URL = databaseUrl.replace(/plasma/g, 'plasma_test');
    process.chdir('core/lib/storage');
    if (reset) {
        await utils.exec('diesel database reset');
        await utils.exec('diesel migration run');
    }
    await utils.spawn('cargo test --release -p zksync_storage --features db_test -- --nocapture');
    process.chdir(process.env.ZKSYNC_HOME as string);
}

export async function contracts() {
    await contract.build();
    await utils.spawn('yarn contracts unit-test');
}

export async function circuit(threads: number = 1, testName?: string, ...args: string[]) {
    await utils.spawn(
        `cargo test --no-fail-fast --release -p zksync_circuit ${testName || ''} 
         -- --ignored --test-threads ${threads} ${args.join(' ')}`
    );
}

export async function prover() {
    await utils.spawn('cargo test -p zksync_prover --release -- --ignored');
}

export async function js() {
    await utils.spawn('yarn zksync tests');
    await utils.spawn('yarn fee-seller tests');
}

export async function rust() {
    await utils.spawn('cargo test --release');
    await db(true);
    await prover();
    const { stdout: threads } = await utils.exec('nproc');
    await circuit(parseInt(threads));
}

export const command = new Command('test').description('run test suites').addCommand(integration.command);

command.command('js').description('run unit-tests for javascript packages').action(js);
command.command('prover').description('run unit-tests for the prover').action(prover);
command.command('contracts').description('run unit-tests for the contracts').action(contracts);
command.command('rust').description('run unit-tests for all rust binaries and libraries').action(rust);

command
    .command('db')
    .description('run unit-tests for the database')
    .option('--reset')
    .action(async (cmd: Command) => {
        await db(cmd.reset);
    });

command
    .command('circuit [threads] [test_name] [options...]')
    .description('run unit-tests for the circuit')
    .allowUnknownOption()
    .action(async (threads: number | null, testName: string | null, options: string[]) => {
        await circuit(threads || 1, testName || '', ...options);
    });
