import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';

export interface LibreswanVpnGatewayProps {
  /**
   * VPC where the Libreswan instance will be deployed
   */
  vpc: ec2.IVpc;
  
  /**
   * Name tag for the instance
   */
  instanceName: string;
  
  /**
   * Remote VPN Gateway public IP (eu-central VPN Gateway tunnel endpoint)
   * This will be configured later via user-data or SSM
   */
  remoteVpnGatewayIp?: string;
  
  /**
   * Local VPC CIDR for routing
   */
  localCidr: string;
  
  /**
   * Remote VPC CIDR for routing
   */
  remoteCidr: string;
}

/**
 * CDK Construct for deploying a Libreswan VPN gateway EC2 instance
 * This acts as a customer gateway to establish Site-to-Site VPN with AWS VPN Gateway
 */
export class LibreswanVpnGateway extends Construct {
  public readonly instance: ec2.Instance;
  public readonly securityGroup: ec2.SecurityGroup;
  public readonly elasticIp: ec2.CfnEIP;
  
  constructor(scope: Construct, id: string, props: LibreswanVpnGatewayProps) {
    super(scope, id);
    
    // Create security group for VPN traffic
    this.securityGroup = new ec2.SecurityGroup(this, 'VpnSecurityGroup', {
      vpc: props.vpc,
      description: 'Security group for Libreswan VPN gateway',
      allowAllOutbound: true,
    });
    
    // Allow IPsec traffic from anywhere
    // Note: AWS VPN Gateway tunnel endpoints are dynamically assigned and cannot be known at CDK synthesis time
    // IPsec protocol includes cryptographic authentication, so source IP filtering provides limited additional security
    // For production: Consider using AWS Network Firewall or additional network segmentation
    
    // UDP 500 - IKE (Internet Key Exchange)
    this.securityGroup.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.udp(500),
      'Allow IKE for VPN tunnel establishment'
    );
    
    // UDP 4500 - NAT-T (NAT Traversal)
    this.securityGroup.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.udp(4500),
      'Allow NAT-T for VPN tunnel with NAT'
    );
    
    // Protocol 50 - ESP (Encapsulating Security Payload)
    this.securityGroup.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.esp(),
      'Allow ESP for encrypted VPN traffic'
    );
    
    // NO SSH ACCESS - Use AWS Systems Manager Session Manager for administrative access
    // The instance has AmazonSSMManagedInstanceCore policy attached for SSM access
    // To connect: aws ssm start-session --target <instance-id> --region eusc-de-east-1 --profile eusc-de
    
    // ICMP removed - not required for VPN operation
    // If needed for troubleshooting, temporarily add via AWS Console with specific source IP
    
    // Create IAM role for the instance
    const role = new iam.Role(this, 'VpnInstanceRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      description: 'IAM role for Libreswan VPN gateway instance',
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
      ],
    });
    
    // Allow instance to describe VPN connections (for auto-configuration)
    role.addToPolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: [
          'ec2:DescribeVpnConnections',
          'ec2:DescribeVpnGateways',
          'ec2:DescribeCustomerGateways',
        ],
        resources: ['*'],
      })
    );
    
    // User data script to install and configure Libreswan
    const userData = ec2.UserData.forLinux();
    userData.addCommands(
      '#!/bin/bash',
      'set -e',
      '',
      '# Update system',
      'yum update -y',
      '',
      '# Install Libreswan',
      'yum install -y libreswan',
      '',
      '# Enable IP forwarding',
      'echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf',
      'echo "net.ipv4.conf.all.accept_redirects = 0" >> /etc/sysctl.conf',
      'echo "net.ipv4.conf.all.send_redirects = 0" >> /etc/sysctl.conf',
      'sysctl -p',
      '',
      '# Disable source/destination check will be done via CDK',
      '',
      '# Create placeholder configuration',
      '# Actual configuration will be applied by setup script after VPN connection is created',
      'cat > /etc/ipsec.d/aws-vpn.conf << EOF',
      '# Placeholder - will be configured by setup-vpn.sh script',
      '# Connection will be established after eu-central VPN Gateway tunnel IPs are discovered',
      'EOF',
      '',
      '# Enable and start IPsec service',
      'systemctl enable ipsec',
      'systemctl start ipsec',
      '',
      '# Log completion',
      'echo "Libreswan VPN gateway installation complete" > /var/log/vpn-setup.log',
      'echo "Waiting for VPN configuration from setup-vpn.sh script" >> /var/log/vpn-setup.log'
    );
    
    // Create EC2 instance
    this.instance = new ec2.Instance(this, 'VpnInstance', {
      vpc: props.vpc,
      vpcSubnets: {
        subnetType: ec2.SubnetType.PUBLIC, // Must be in public subnet for VPN
      },
      instanceType: ec2.InstanceType.of(
        ec2.InstanceClass.T3,
        ec2.InstanceSize.MICRO
      ),
      machineImage: ec2.MachineImage.latestAmazonLinux2023({
        cpuType: ec2.AmazonLinuxCpuType.X86_64,
      }),
      securityGroup: this.securityGroup,
      role: role,
      userData: userData,
      sourceDestCheck: false, // Required for VPN gateway to route traffic
      blockDevices: [
        {
          deviceName: '/dev/xvda',
          volume: ec2.BlockDeviceVolume.ebs(8, {
            volumeType: ec2.EbsDeviceVolumeType.GP3,
            encrypted: true,
          }),
        },
      ],
    });
    
    // Add name tag
    cdk.Tags.of(this.instance).add('Name', props.instanceName);
    
    // Allocate Elastic IP
    this.elasticIp = new ec2.CfnEIP(this, 'VpnElasticIp', {
      domain: 'vpc',
      tags: [
        {
          key: 'Name',
          value: `${props.instanceName}-EIP`,
        },
      ],
    });
    
    // Associate Elastic IP with instance
    new ec2.CfnEIPAssociation(this, 'VpnEipAssociation', {
      allocationId: this.elasticIp.attrAllocationId,
      instanceId: this.instance.instanceId,
    });
    
    // Add route to private subnets pointing remote CIDR to Libreswan instance
    // This allows traffic destined for the remote VPC to route through the VPN
    const privateSubnets = props.vpc.privateSubnets;
    privateSubnets.forEach((subnet, index) => {
      new ec2.CfnRoute(this, `VpnRoute${index}`, {
        routeTableId: subnet.routeTable.routeTableId,
        destinationCidrBlock: props.remoteCidr,
        instanceId: this.instance.instanceId,
      });
    });
    
    // Output the public IP
    new cdk.CfnOutput(this, 'VpnGatewayPublicIp', {
      value: this.elasticIp.ref,
      description: `Public IP of ${props.instanceName}`,
      exportName: `${props.instanceName}-PublicIp`,
    });
    
    // Output the instance ID
    new cdk.CfnOutput(this, 'VpnGatewayInstanceId', {
      value: this.instance.instanceId,
      description: `Instance ID of ${props.instanceName}`,
      exportName: `${props.instanceName}-InstanceId`,
    });
  }
}
